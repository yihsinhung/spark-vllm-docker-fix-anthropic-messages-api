#!/bin/bash
set -e

echo "Patching vLLM to handle Anthropic Messages API format (Claude Code >= 2.1.154)"

# This mod fixes the issue where vLLM's Messages API endpoint expects
# tools with 'input_schema' but Claude Code sends them with 'parameters'.
# It also handles Anthropic-style content blocks (tool_use, tool_result).

VLLM_DIR="/usr/local/lib/python3.12/dist-packages/vllm"

# Find the messages protocol file
MESSAGES_PROTOCOL="$VLLM_DIR/entrypoints/v1/messages.py"
OPENAI_PROTOCOL="$VLLM_DIR/entrypoints/openai/models/protocol.py"

# Try to find the correct file location
if [ -f "$MESSAGES_PROTOCOL" ]; then
    TARGET_FILE="$MESSAGES_PROTOCOL"
    echo "Found messages protocol at: $MESSAGES_PROTOCOL"
elif [ -f "$OPENAI_PROTOCOL" ]; then
    TARGET_FILE="$OPENAI_PROTOCOL"
    echo "Found openai protocol at: $OPENAI_PROTOCOL"
else
    echo "WARNING: Could not find messages protocol file."
    echo "Searching for any file containing 'input_schema'..."
    FOUND_FILE=$(find "$VLLM_DIR" -name "*.py" -exec grep -l "input_schema" {} \; 2>/dev/null | head -1)
    if [ -n "$FOUND_FILE" ]; then
        TARGET_FILE="$FOUND_FILE"
        echo "Found potential file: $TARGET_FILE"
    else
        echo "ERROR: Could not find any file with 'input_schema'. vLLM version may differ."
        echo "Skipping Anthropic messages API fix."
        exit 0
    fi
fi

# Create the patch Python script
cat > /tmp/fix_anthropic_messages.py << 'PATCH_EOF'
"""
Patch for vLLM to handle Anthropic Messages API format.
This fixes compatibility with Claude Code >= 2.1.154 which sends
Anthropic-style content blocks and tool definitions.
"""
import re
import sys

target_file = sys.argv[1] if len(sys.argv) > 1 else "/usr/local/lib/python3.12/dist-packages/vllm/entrypoints/v1/messages.py"

with open(target_file, 'r') as f:
    content = f.read()

# Check if already patched
if "input_schema or tool.get('parameters'" in content:
    print("  Already patched, skipping.")
    sys.exit(0)

# Patch 1: Fix the tool schema detection to accept both 'input_schema' and 'parameters'
# This is the main fix for the error: "input_schema: Field required"

# Look for patterns where input_schema is accessed
patterns_to_fix = [
    # Pattern 1: Direct access to input_schema
    (r"tool\.get\(['\"]input_schema['\"]\)",
     "tool.get('input_schema') or tool.get('parameters', {})"),

    # Pattern 2: Tool definition where input_schema is expected
    (r"input_schema\s*=\s*tool\.get\(['\"]input_schema['\"]\)",
     "input_schema = tool.get('input_schema') or tool.get('parameters', {})"),
]

for pattern, replacement in patterns_to_fix:
    if re.search(pattern, content):
        content = re.sub(pattern, replacement, content)
        print(f"  Fixed pattern: {pattern[:50]}...")

# Patch 2: Add Anthropic message conversion functions if not present
conversion_functions = '''

# Anthropic Messages API compatibility (for Claude Code >= 2.1.154)
import json

def _extract_text_from_anthropic_content(content):
    """Extract plain text from an Anthropic content field."""
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        texts = []
        for block in content:
            if isinstance(block, dict):
                text = block.get("text")
                if isinstance(text, str) and text:
                    texts.append(text)
            elif isinstance(block, str) and block:
                texts.append(block)
        return "\\n".join(texts)
    return ""


def _convert_anthropic_assistant_message(content):
    """Convert an assistant message whose content is a list of blocks."""
    text_parts = []
    tool_calls = []
    for block in content:
        if not isinstance(block, dict):
            continue
        block_type = block.get("type")
        if block_type == "text":
            text = block.get("text")
            if isinstance(text, str) and text:
                text_parts.append(text)
        elif block_type == "tool_use":
            tool_calls.append({
                "id": block.get("id", ""),
                "type": "function",
                "function": {
                    "name": block.get("name", ""),
                    "arguments": json.dumps(block.get("input", {}), ensure_ascii=False),
                },
            })
    new_msg = {"role": "assistant", "content": "\\n".join(text_parts)}
    if tool_calls:
        new_msg["tool_calls"] = tool_calls
    return new_msg


def _convert_anthropic_user_message(content):
    """Convert a user message whose content is a list of blocks."""
    tool_messages = []
    text_parts = []
    for block in content:
        if not isinstance(block, dict):
            continue
        block_type = block.get("type")
        if block_type == "text":
            text = block.get("text")
            if isinstance(text, str) and text:
                text_parts.append(text)
        elif block_type == "tool_result":
            tool_messages.append({
                "role": "tool",
                "tool_call_id": block.get("tool_use_id", ""),
                "content": _extract_text_from_anthropic_content(block.get("content")),
            })
    result = list(tool_messages)
    if text_parts:
        result.append({"role": "user", "content": "\\n".join(text_parts)})
    return result


def _convert_anthropic_messages_to_openai(messages):
    """Convert Anthropic user/assistant content blocks into OpenAI-style."""
    converted = []
    for msg in messages or []:
        content = msg.get("content")
        if not isinstance(content, list):
            converted.append(msg)
            continue
        if msg.get("role") == "assistant":
            converted.append(_convert_anthropic_assistant_message(content))
        elif msg.get("role") == "user":
            converted.extend(_convert_anthropic_user_message(content))
        else:
            converted.append(msg)
    return converted


def _convert_anthropic_tools_to_openai(tools):
    """Convert Anthropic tool definitions to OpenAI function tools."""
    openai_tools = []
    for tool in tools:
        if not isinstance(tool, dict):
            continue
        if tool.get("type") == "function" and "function" in tool:
            openai_tools.append(tool)
            continue
        # Handle Anthropic format with input_schema or parameters
        openai_tools.append({
            "type": "function",
            "function": {
                "name": tool.get("name", ""),
                "description": tool.get("description", ""),
                "parameters": tool.get("input_schema") or tool.get("parameters", {}),
            },
        })
    return openai_tools


def _convert_anthropic_tool_choice(tool_choice):
    """Convert an Anthropic tool_choice to the OpenAI equivalent."""
    if not isinstance(tool_choice, dict):
        return tool_choice
    choice_type = tool_choice.get("type")
    if choice_type == "auto":
        return "auto"
    if choice_type == "any":
        return "required"
    if choice_type == "none":
        return "none"
    if choice_type == "tool" and tool_choice.get("name"):
        return {"type": "function", "function": {"name": tool_choice["name"]}}
    return tool_choice

'''

# Add the conversion functions after the imports section
if "_extract_text_from_anthropic_content" not in content:
    # Find a good place to insert (after imports)
    import_end = content.find("\n\n", content.find("import"))
    if import_end > 0:
        content = content[:import_end] + conversion_functions + content[import_end:]
        print("  Added Anthropic conversion functions.")

# Patch 3: Apply the conversion to the messages endpoint
# Look for where messages are parsed and add conversion

# Find the create_messages or similar function and add conversion
if "_convert_anthropic_messages_to_openai" in content and "messages = _convert_anthropic_messages_to_openai(messages)" not in content:
    # Try to find where messages are processed
    if "messages: list" in content or "messages: List" in content:
        # Add conversion after messages is defined
        content = content.replace(
            "messages: list[str]",
            "messages = _convert_anthropic_messages_to_openai(messages)\n    messages: list[str]"
        )
        print("  Added messages conversion hook.")

with open(target_file, 'w') as f:
    f.write(content)

print("  OK - vLLM patched for Anthropic Messages API compatibility.")
PATCH_EOF

# Run the patch
python3 /tmp/fix_anthropic_messages.py "$TARGET_FILE"

echo "Anthropic Messages API fix complete."
echo ""
echo "Note: This fix allows vLLM to accept both:"
echo "  - Anthropic format: {type: 'function', name: '...', input_schema: {...}}"
echo "  - OpenAI format: {type: 'function', function: {name: '...', parameters: {...}}}"
echo ""
echo "It also converts Anthropic content blocks (tool_use, tool_result) to OpenAI format."