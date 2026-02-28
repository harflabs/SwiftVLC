@testable import SwiftVLC
import CLibVLC
import Foundation
import Testing

@Suite("Program", .tags(.integration), .serialized)
struct ProgramTests {
  @Test("Programs empty for simple media", .tags(.mainActor))
  @MainActor
  func programsEmptyForSimpleMedia() throws {
    let player = try Player()
    #expect(player.programs.isEmpty)
  }

  @Test("Selected program nil", .tags(.mainActor))
  @MainActor
  func selectedProgramNil() throws {
    let player = try Player()
    #expect(player.selectedProgram == nil)
  }

  @Test("Program is Sendable")
  func programIsSendable() {
    let _: any Sendable.Type = Program.self
  }

  @Test("Program conforms to Identifiable and Hashable")
  func conformances() {
    let _: any Identifiable.Type = Program.self
    let _: any Hashable.Type = Program.self
  }

  @Test("Init from C struct", .tags(.logic))
  func initFromCStruct() throws {
    let name = try #require(strdup("Test Program"))
    defer { free(name) }

    let cProgram = libvlc_player_program_t(
      i_group_id: 42,
      psz_name: name,
      b_selected: true,
      b_scrambled: false
    )
    let program = Program(from: cProgram)
    #expect(program.id == 42)
    #expect(program.name == "Test Program")
    #expect(program.isSelected == true)
    #expect(program.isScrambled == false)
  }

  @Test("Init from C struct scrambled", .tags(.logic))
  func initFromCStructScrambled() throws {
    let name = try #require(strdup("Encrypted Channel"))
    defer { free(name) }

    let cProgram = libvlc_player_program_t(
      i_group_id: 7,
      psz_name: name,
      b_selected: false,
      b_scrambled: true
    )
    let program = Program(from: cProgram)
    #expect(program.id == 7)
    #expect(program.name == "Encrypted Channel")
    #expect(program.isSelected == false)
    #expect(program.isScrambled == true)
  }

  @Test("Hashable with same values", .tags(.logic))
  func hashableWithSameValues() throws {
    let nameA = try #require(strdup("Channel"))
    let nameB = try #require(strdup("Channel"))
    defer { free(nameA); free(nameB) }

    let a = Program(from: libvlc_player_program_t(
      i_group_id: 1, psz_name: nameA, b_selected: false, b_scrambled: false
    ))
    let b = Program(from: libvlc_player_program_t(
      i_group_id: 1, psz_name: nameB, b_selected: false, b_scrambled: false
    ))
    #expect(a == b)
    let set: Set<Program> = [a, b]
    #expect(set.count == 1)
  }
}
