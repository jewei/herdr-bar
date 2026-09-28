# Troubleshoot Herdr Bar

## Restore a connection

If the palette shows **Offline**, do these checks:

1. Check that Herdr is running.
2. Compare the Herdr session's socket path with **Settings** > **Connection**.
3. If the paths differ, save the correct socket path.
4. Refresh the palette.

If you open the app from Finder or at login, set the socket path in
**Connection**. These launch methods normally do not receive your shell variables.
To use the environment and default path again, clear **Connection**.
The [socket path order](../README.md#connection) lists the available settings.

After a failed connection, the app retries with an increasing delay, up to
30 seconds.

## Inspect polling mode

If the palette shows **Polling**, hover over the label to read the event stream
error. Snapshots still work in this mode. The app retries the event subscription.
An established stream can remain connected without events.

## Select the correct terminal

If the app activates the wrong terminal, select your terminal in **Settings**.

**Automatic** checks attached Herdr clients and their parent processes. With
multiple clients, it uses the first matching application. If no application
matches, it tries running terminals in this order:

1. Ghostty
2. iTerm2
3. Terminal
4. WezTerm
5. Warp

SSH and nested terminal multiplexers can prevent host detection. Selection of a
specific outer window or tab is not guaranteed.

## Restore notifications

1. Enable notifications in Herdr Bar.
2. Enable Herdr Bar notifications in **System Settings** > **Notifications**.
3. Check that **Focus** permits the notifications.

The initial snapshot does not send notifications. Opening an agent or marking
completed agents as read clears local completion attention. Opening a blocked
agent leaves its blocked state unchanged.
