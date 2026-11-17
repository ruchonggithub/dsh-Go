/// Which of the app's optional halves this build offers.
///
/// Two different ideas live here, and they are deliberately separate:
///
/// - **Entertainment** is a runtime preference
///   (`state/entertainment_state.dart`): tavern, companion, pets, bots, the
///   community page and forum, wallpapers, share posters, replay, and the
///   effects around them. The person turns it on or off in 设置; the code is
///   always compiled. Nothing here decides that.
/// - **Links to the project's servers** are build-time constants below. They
///   are about where the app is allowed to talk, not about what it offers.
///
/// What stays on regardless, because the app does not work without it:
/// - the model provider the person configures (DeepSeek or their own endpoint);
/// - GitHub releases, the only source updates are checked against;
/// - a DSH Remote server the person adds by address themselves.
library;

/// The forum (`forum.dshtui.com`) and the workshop/plugin market that signs in
/// through it.
///
/// Off in this build: no requests to the forum host, and its screens are gated
/// by the entertainment switch like the rest of the community half. The code
/// stays, so setting this to true is all a build needs to bring it back.
const bool forumEnabled = false;

/// The workshop (plugin market uploads, companion packages). Requires
/// [forumEnabled]: authorisation is an assertion about a forum account.
const bool workshopEnabled = forumEnabled;

/// The project's own copy of the release files and its beta channel. Off: the
/// update checker asks GitHub only.
const bool projectUpdateHostsEnabled = false;

/// The hosted DSH Remote server offered as a default. Off: a Remote host is
/// added by typing its address.
const bool hostedRelayServerEnabled = false;

/// The anonymous usage counters. Kept as a default but still a setting the
/// person controls; this constant only says whether the feature is offered.
const bool usageStatsEnabled = true;
