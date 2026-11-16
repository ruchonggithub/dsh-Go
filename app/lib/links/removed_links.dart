/// Which third-party services this build talks to.
///
/// The app is the upstream client with its optional external links removed.
/// "Removed" here means *not offered*: no entry point in the UI, no request
/// made. The implementing code stays in the tree, so restoring a feature is a
/// one-line change of the constant below rather than a rewrite.
///
/// What stays on, because the app cannot work without it:
/// - the model provider the person configures (DeepSeek or their own endpoint);
/// - GitHub releases, the only source updates are checked against;
/// - a DSH Remote server the person adds by address themselves.
///
/// What is off in this build:
/// - the project's forum (`forum.dshtui.com`) and everything that signs in to
///   it, including the workshop/plugin market it authorises;
/// - the project's own update copy, its beta channel and the public GitHub
///   accelerators — updates now come from GitHub alone;
/// - the hosted DSH Remote server (`dsh.r2049.cn`), so a Remote host has to be
///   entered by hand.
library;

/// The forum, and with it the workshop and plugin market that log in through
/// it. Off: no forum screens, no requests to the forum host.
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
