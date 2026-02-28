import CLibVLC

/// A program (DVB/MPEG-TS service) within a media stream.
///
/// Programs are discovered by the player and can be selected
/// via ``Player/selectProgram(id:)`` or ``Player/programs``.
public struct Program: Sendable, Identifiable, Hashable {
  /// The program group ID.
  public let id: Int
  /// The program name.
  public let name: String
  /// Whether this program is currently selected.
  public let isSelected: Bool
  /// Whether this program is scrambled (encrypted).
  public let isScrambled: Bool

  init(from cProgram: libvlc_player_program_t) {
    id = Int(cProgram.i_group_id)
    name = String(cString: cProgram.psz_name)
    isSelected = cProgram.b_selected
    isScrambled = cProgram.b_scrambled
  }
}
