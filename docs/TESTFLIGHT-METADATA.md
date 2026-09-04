# TestFlight metadata

Use these values for the first TestFlight build. Keep reviewer credentials and personal contact
details in App Store Connect only; never commit them to this repository.

## App record

- Platform: iOS
- Name: OnlyX Login
- Primary language: English (U.S.)
- Bundle ID: `ai.onlyx.login`
- SKU: `onlyx-login-ios`
- User access: Full Access

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

## Before external testing

- Add a non-production reviewer account in App Store Connect. Reviewer credentials must not
  expire; the one-time connect link must be supplied separately when Apple begins review.
- Enter an actively monitored review contact name, email, and international-format phone number.
- Create an internal group first, then an external group named `OnlyX Login Beta`.
- Upload a signed archive, answer export compliance, attach build 1 to the external group, paste
  the **What to test** text above, and submit the first build for TestFlight App Review.
- Enable the public link only after Apple approves the build.

## App Store follow-up

A public App Store release additionally needs a published privacy-policy URL, the App Privacy data
handling answers, age rating, category, support URL, screenshots, and complete version metadata.
Those are not required to produce the first internal TestFlight build.
