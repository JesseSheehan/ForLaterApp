# For Later

Share a screenshot or link to For Later, and Apple's on-device AI turns it into a reminder card. You get reminded at your daily check-in times to clear your desk.

Plan: https://claude.ai/artifact/ACBTwV1Pm41h2b5eKGCqot

## Project layout

| Folder | What's in it |
| --- | --- |
| `ForLater/` | The iPhone app: the desk list |
| `ForLaterShare/` | The share extension that receives screenshots and links |
| `Shared/` | Code used by both: data model, iCloud store, AI analyzer, the For Later card |
| `Config/` | Info.plist additions and entitlements |

## First-time setup in Xcode

1. Open `ForLater.xcodeproj`.
2. For both the **ForLater** and **ForLaterShare** targets, open **Signing & Capabilities** and choose your team.
3. If Xcode flags the App Group or iCloud container, click the refresh button next to each, or remove and re-add:
   - App Groups: `group.com.jessesheehan.ForLater`
   - iCloud (CloudKit): `iCloud.com.jessesheehan.ForLater`
4. Run the **ForLater** scheme on your iPhone, then share a screenshot to "For Later" from the share sheet.

If the bundle IDs are already taken, change `com.jessesheehan.ForLater` in both targets and in `Shared/DataStore.swift`.

## Status (phase 1)

- Share a screenshot or link and the card opens with the AI's suggestions. Edit it and tap the check button.
- AI: Vision reads the text, then Apple's on-device model writes the title, picks the category and adds notes. Without Apple Intelligence, it fills in the text and link only.
- If the share sheet closes before the AI finishes, the app finishes the job when it opens.
- Desk list: tap to edit, tap the circle or swipe right to complete, swipe left to delete.
- Coming next: onboarding (choose 1 to 12 check-in times), notifications, the "Clear desk" starter item, confetti, and the Mac app.
