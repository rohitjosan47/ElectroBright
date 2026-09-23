import 'eb_command.dart';
import 'eb_reply.dart';

/// How a reply line relates to the command currently awaiting one.
enum ReplyMatch {
  /// Final reply: the command succeeded.
  success,

  /// Final reply: the command failed (see the EbError).
  failure,

  /// Belongs to the command but is not final (ERROR:STORAGE before OK).
  note,

  /// Might be final: ERROR:STORAGE for a preset write. If an OK follows within
  /// a grace period it was an unsolicited background error instead.
  provisional,

  /// Not a reply to this command (unsolicited or stray).
  none,
}

/// The firmware reply grammar (firmware ControllerCore::execute): which lines
/// can answer which command. Replies carry no request id, so this is what
/// keeps request/response matching exact.
ReplyMatch matchReply(EbExpect expect, EbReply reply) {
  // A command the firmware does not know marks that capability unsupported.
  if (reply is EbError && reply.code == EbError.unknownCommand) {
    return ReplyMatch.failure;
  }
  switch (expect) {
    case EbExpect.ok:
      if (reply is EbOk) return ReplyMatch.success;
      if (reply is EbError &&
          reply.code != EbError.storage &&
          reply.code != EbError.presetEmpty) {
        return ReplyMatch.failure;
      }
      return ReplyMatch.none;
    case EbExpect.okStorageNote:
      if (reply is EbOk) return ReplyMatch.success;
      if (reply is EbError) {
        if (reply.code == EbError.storage) return ReplyMatch.note;
        if (reply.code != EbError.presetEmpty) return ReplyMatch.failure;
      }
      return ReplyMatch.none;
    case EbExpect.okStorageProvisional:
      if (reply is EbOk) return ReplyMatch.success;
      if (reply is EbError) {
        if (reply.code == EbError.storage) return ReplyMatch.provisional;
        if (reply.code != EbError.presetEmpty) return ReplyMatch.failure;
      }
      return ReplyMatch.none;
    case EbExpect.presetLoad:
      // PRESET_LOAD wakes the light before replying, so its STATUS always has
      // sleeping=0; a sleeping STATUS is the unsolicited timer-expiry push.
      if (reply is EbStatusReply) {
        return reply.status.sleeping ? ReplyMatch.none : ReplyMatch.success;
      }
      if (reply is EbError &&
          (reply.code == EbError.presetEmpty ||
              reply.code == EbError.presetIdInvalid ||
              reply.code == EbError.format)) {
        return ReplyMatch.failure;
      }
      return ReplyMatch.none;
    case EbExpect.info:
      return reply is EbInfo ? ReplyMatch.success : _queryError(reply);
    case EbExpect.version:
      return reply is EbVersion ? ReplyMatch.success : _queryError(reply);
    case EbExpect.caps:
      return reply is EbCaps ? ReplyMatch.success : _queryError(reply);
    case EbExpect.status:
      return reply is EbStatusReply ? ReplyMatch.success : _queryError(reply);
    case EbExpect.modeSettings:
      return reply is EbModeSettings ? ReplyMatch.success : _queryError(reply);
    case EbExpect.presets:
      return reply is EbPresets ? ReplyMatch.success : _queryError(reply);
    case EbExpect.capabilities:
      if (reply is EbCapabilities) return ReplyMatch.success;
      if (reply is EbError && reply.code == EbError.modeInvalid) {
        return ReplyMatch.failure;
      }
      return _queryError(reply);
    case EbExpect.diag:
      return reply is EbDiag ? ReplyMatch.success : _queryError(reply);
  }
}

ReplyMatch _queryError(EbReply reply) =>
    reply is EbError && reply.code == EbError.format
    ? ReplyMatch.failure
    : ReplyMatch.none;
