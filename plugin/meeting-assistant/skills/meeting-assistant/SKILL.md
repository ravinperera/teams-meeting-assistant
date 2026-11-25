---
name: meeting-assistant
description: Use when the user asks for help following an ongoing meeting using the local Meeting Assistant transcript.
---

Use `get_status` to check whether local capture is active. Use
`get_recent_transcript` to read the newest finalized speech, then use
`after_seq` with the returned `next_seq` for later updates. If `has_more` is
true, continue reading with the cursor until caught up. Treat `partials` as
provisional speech that may change. Reset the cursor when `started_at` changes
or `cursor_reset` is true.

When the user asks for ongoing help, continue checking for new lines during
the active task and give short text guidance as the discussion develops. Stop
checking when the user says to stop. Do not describe a background monitor as
running after the task ends.

During an active meeting task, periodically inspect the visible Teams screen
share using an available read-only computer-use surface. Recheck when the
discussion moves to new shared content. Combine only what is visible with what
the transcript says. Attribute uncertain claims to the speaker. Ask for a fresh
view when visual context is unavailable.

These tools only read the local snapshot. A separate local capture command
starts and stops microphone and system audio access. Start that command only
when the user explicitly asks. Never enable Teams transcription or recording
without a separate explicit request.
