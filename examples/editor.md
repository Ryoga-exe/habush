# Interactive editing

Run `habush --config examples/config.zon` to try the keybinding example.
Editing is enabled automatically on supported POSIX terminals; Windows still
uses cooked line input.

| Key | Default action |
| --- | --- |
| Up / Ctrl+P, Down / Ctrl+N | Previous/next history entry; select candidates while a completion menu is open |
| Ctrl+L | Clear the visible screen and redraw the current input, preserving the cursor and Undo |
| Tab, Shift+Tab | Complete or move forward/backward through candidates |
| Enter | Insert the selected candidate, or submit input when no menu is open |
| Escape | Dismiss the menu |
| Ctrl+A/E, Ctrl+B/F | Start/end, previous/next character |
| Ctrl+K/U | Delete to end/start |
| Ctrl+_ | Undo the last edit |
| Ctrl+C, Ctrl+D | Cancel input, or EOF/delete |

History contains submitted source, including compound commands and here-documents.
Returning past the newest entry restores the draft and its cursor. Consecutive
duplicates and blank input are omitted. It retains at most 1000 entries and
1 MiB in this process; inputs over the editor's 64 KiB limit are omitted.
History is not saved to disk. Continuation and here-document prompts do not
navigate command history.

The ZON `keybinds` list maps `key` to `action`. Named keys are `up`, `down`,
`left`, `right`, `home`, `end`, `delete`, `backtab`, `enter`, `tab`, `backspace`,
`escape`, and `space`. Single printable ASCII keys and `ctrl+<letter>` are also
supported, including `ctrl+space` and `ctrl+_`. Terminal aliases normalize to
the same key: Ctrl+I/Tab, Ctrl+J/Ctrl+M/Enter, Ctrl+H/Backspace.

Later bindings override earlier ones and defaults. `ignore` consumes the key;
`unbind` removes the action, leaving printable keys as text and ringing the bell
for other unhandled keys. Invalid triggers/actions fail configuration loading.
See [the action enum](../src/lib/edit/Keybind.zig) for available actions.

The trigger/action separation and override order follow the approach in
[Ghostty's keybinding documentation](https://ghostty.org/docs/config/keybind).
This terminal editor does not implement Ghostty's GUI/global keys or key sequences.
The `complete` action uses the existing application-supplied completion service;
it grants no new permissions to plugins. See [plugin examples](plugins/README.md).
