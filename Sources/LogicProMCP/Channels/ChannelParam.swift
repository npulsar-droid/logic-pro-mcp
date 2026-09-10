import Foundation

/// Parameter keys shared between dispatchers and channels.
///
/// `ChannelRouter.route` forwards a dispatcher's params to each channel in the
/// fallback chain verbatim, so a dispatcher and a channel that spell the same
/// key differently do not fail loudly — the mismatched channel just reports a
/// missing parameter, which the router treats as "this channel could not do
/// it" and moves on. That is how set_tempo shipped with a dead Accessibility
/// fallback: the dispatcher sent "bpm", the channel read "tempo".
///
/// Keys that cross that boundary belong here, spelled once.
enum ChannelParam {
    /// Tempo in beats per minute.
    static let tempo = "bpm"
}
