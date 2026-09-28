# Check a release on macOS

Use a disposable Herdr session and a built app installed in `~/Applications`.
Keep production sessions and working terminals unchanged.

Record the source commit, app version, macOS version, CPU architecture,
Herdr version, terminal application, and each result.
For release 1.0.1, apply the
[owner's check exclusions](native-verification.md#release-101-check-exclusions).
Do not record an excluded check as passed.

## Check notifications

1. Enable notification permission for Herdr Bar.
2. Check that **Focus** and **Do Not Disturb** permit notifications.
3. Complete two tasks in the same agent.
4. Check that each completion sends a new notification.
5. Refresh without a state change.
6. Check that the unchanged snapshot sends no additional notification.
7. Move the pane to another workspace.
8. Open its notification.
9. Check that the notification opens the agent at its new address.
10. Replace the agent session.
11. Open an old notification.
12. Check that it neither opens nor acknowledges the replacement agent.
13. Restore the original notification setting.

## Check terminal focus

Repeat these checks with **Automatic** and an explicit terminal selection.
Use multiple windows, multiple attached clients, and named sessions.

1. Open an agent from Herdr Bar.
2. Check which pane the terminal displays.
   Activation of the application alone does not establish correct pane selection.
3. Select an unavailable terminal.
4. Try to open an unread completion.
5. Check that the app reports the activation failure.
6. Check that the completion remains unread.

Selection of a specific outer terminal window or tab is not guaranteed.

## Check connection recovery

1. Set **Connection** to the disposable session's socket path.
2. Stop that session.
3. Check that Herdr Bar reports **Disconnected**.
4. Restart the test session.
5. Check that the app recovers through **Polling** to **Live**.
6. Check that an obsolete connection cannot change rows in the new connection.

Short work cycles completed entirely during a connection gap can be lost.

## Check startup at login

1. Enable startup at login in Herdr Bar.
2. Check registration in **System Settings** > **General** > **Login Items**.
3. Log out.
4. Log in.
5. Check that a single Herdr Bar instance starts and works.
6. Restore the original login setting.

Registration alone does not establish startup after login.

## Check the distribution archive

Check each distribution property separately:

1. Validate the Developer ID signature.
2. Validate Apple notarization and the stapled ticket.
3. Check the archive checksum.
4. Check Gatekeeper assessment of the extracted app.
5. Test execution on the oldest supported macOS version.
6. Test each CPU architecture that you plan to distribute.

Preview images and unit tests on the build host do not establish these results.
Record the results and unperformed checks in the
[native verification record](native-verification.md).
