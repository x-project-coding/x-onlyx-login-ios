# TestFlight metadata

Use these values for the first TestFlight build. Keep reviewer credentials and personal contact
details in App Store Connect only; never commit them to this repository.

## App record

- Platform: iOS
- Name: OnlyX Login
- App Store Connect Apple ID: `6808706039`
- Primary language: English (U.S.)
- Bundle ID: `ai.onlyx.login`
- SKU: `onlyx-login-ios`
- User access: Full Access

## Internal testing

- Group: `OnlyX Internal`
- Automatic distribution: enabled
- Build: `1.0 (1)`
- Testers: 1 configured in App Store Connect

## External testing

- Group: `OnlyX Login Beta`
- Build: `1.0 (1)`
- Beta App Review status: Rejected on September 5, 2026; requested demo video supplied and
  response sent to App Review
- Public link: <https://testflight.apple.com/join/fk6C6an3>
- Public-link access: open to anyone, with no tester limit

The public link becomes joinable after Apple approves the build for external testing.

## Test information

### Beta app description

OnlyX Login is a sign-in helper for creators who need to connect their own OnlyFans account to an
OnlyX-managed workspace. A creator opens or pastes a one-time link from their manager, signs in
inside a private browser, completes any identity check on their iPhone, and waits for Connected.
Browser data is discarded when the run ends.

### What to test

Open or paste an OnlyX connect link. Confirm that the OnlyFans sign-in loads, camera verification
can be completed when requested, and the app reaches Connected. Also verify that expired or invalid
links show a clear recovery message. Use only the designated test creator account.

### Feedback email

`support@onlyx.ai`

### Beta App Review notes

OnlyX Login has no independent user account. A customer manager generates a one-time connect link
for the creator; links expire after 15 minutes and cannot be used twice. The app opens OnlyFans in
an ephemeral WKWebView, sends the signed-in session to the creator's authorized OnlyX workspace,
and discards local website data when the run ends. To exercise the complete flow, contact
support@onlyx.ai so we can issue a fresh review link and designated test account at review time.
Camera access is used only if OnlyFans requests identity verification. The app has no purchases,
subscriptions, ads, or user-generated content.

Demo video recorded on a physical iPhone 17 Pro Max using the current `1.0 (1)` build (not
Simulator): <https://drive.google.com/file/d/1Fhna6Cwxv0lJYRobQdjPjHt3QfNcG39X/view?usp=sharing>

The video demonstrates opening the OnlyX connect invitation in Safari, handing off to OnlyX Login,
and opening the embedded OnlyFans sign-in flow.

## External-testing checklist

- [x] Enter an actively monitored Beta App Review contact.
- [x] Create the `OnlyX Login Beta` external group.
- [x] Upload and validate the signed `1.0 (1)` archive.
- [x] Declare that the app does not use non-exempt encryption.
- [x] Attach the build and submit it to Beta App Review.
- [x] Create the public invite link.
- [x] Add Apple's requested physical-device demo video to Review Notes and reply to App Review.
- [ ] Wait for Apple to continue the review and approve the build; the public link is inactive
  until approval.

## App Store follow-up

A public App Store release additionally needs a published privacy-policy URL, the App Privacy data
handling answers, age rating, category, support URL, screenshots, and complete version metadata.
Those are not required to produce the first internal TestFlight build.
