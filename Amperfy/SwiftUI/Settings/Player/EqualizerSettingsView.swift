//
//  EqualizerSettingsView.swift
//  Amperfy
//
//  Created by Maximilian Bauer on 19.07.25.
//  Copyright (c) 2025 Maximilian Bauer. All rights reserved.
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program.  If not, see <http://www.gnu.org/licenses/>.
//

import AmperfyKit
import SwiftUI

// MARK: - EqualizerSettingsView

struct EqualizerSettingsView: View {
  @EnvironmentObject
  private var settings: Settings

  @State
  private var eqSettingToEdit: EqualizerSetting?
  @State
  private var eqSettingNameSaved: String = ""
  @State
  private var eqSettingName: String = ""
  @State
  var eqSettingGains: [CGFloat] = EqualizerSetting.frequencies.map { _ in 0.0 }
  @State
  var sliderLabel: [String] = EqualizerSetting.frequencies.map {
    if $0 < 1000 {
      return "\(Int($0))"
    } else {
      return "\(Int($0 / 1000))k"
    }
  }

  @State
  var isShowDeleteAlert = false

  var body: some View {
    ZStack {
      SettingsList {
        SettingsSection(content: {
          SettingsCheckBoxRow(
            title: "Equalizer",
            isOn: Binding(
              get: { settings.isEqualizerEnabled },
              set: { isEnabled in
                settings.isEqualizerEnabled = isEnabled
              }
            )
          )

          if settings.isEqualizerEnabled {
            SettingsRow(title: "Preset") {
              Menu(settings.activeEqualizerSetting.description) {
                Button(EqualizerSetting.off.description) {
                  settings.activeEqualizerSetting = EqualizerSetting.off
                }
                ForEach(settings.equalizerSettings, id: \.self) { eqSetting in
                  Button(eqSetting.description) {
                    settings.activeEqualizerSetting = eqSetting
                  }
                }
              }
            }
          }
        })

        SettingsSection(content: {
          SettingsRow(title: "Edit") {
            Menu((eqSettingToEdit != nil) ? eqSettingNameSaved : "Choose a preset") {
              ForEach(settings.equalizerSettings, id: \.self) { eqSetting in
                Button(eqSetting.description) {
                  eqSettingToEdit = eqSetting
                  eqSettingName = eqSetting.name
                  eqSettingNameSaved = eqSetting.name
                  eqSettingGains = eqSetting.gains.compactMap { CGFloat($0) }
                }
              }
              Button("New Preset") {
                let newEQ = EqualizerSetting(name: "New preset")
                var curEqSetting = settings.equalizerSettings
                curEqSetting.append(newEQ)
                settings.equalizerSettings = curEqSetting
                eqSettingToEdit = newEQ
                eqSettingName = newEQ.name
                eqSettingNameSaved = newEQ.name
                eqSettingGains = newEQ.gains.compactMap { CGFloat($0) }
              }
            }
          }

          if eqSettingToEdit != nil {
            SettingsRow(title: "Name") {
              TextField("Preset name", text: $eqSettingName)
                .multilineTextAlignment(.trailing)
            }

            // cassette Patch 050 (Phase E): EQ slider tint + gradient drop
            // to ink2 / ink3. The orange was visually loud against the
            // settings list bg2 surface and competed with the global
            // restraint principles. (After Patch 046 the asColor expression
            // already resolves to ink, but using ink2 / ink3 explicitly
            // here gives the slider a quieter, more "settings" feel.)
            EqualizerView(
              sliderLabels: $sliderLabel,
              sliderValues: $eqSettingGains,
              sliderTintColor: Color.cassette(.textSecondary),
              gradientColors: [Color.cassette(.textTertiary), .clear]
            )

            SettingsButtonRow(title: "Save") {
              guard var eqSettingToEdit else { return }
              var curEqSetting = settings.equalizerSettings
              guard let index = curEqSetting.firstIndex(of: eqSettingToEdit) else { return }
              eqSettingToEdit.name = eqSettingName
              eqSettingNameSaved = eqSettingName
              eqSettingToEdit.gains = eqSettingGains.compactMap { Float($0) }
              self.eqSettingToEdit = eqSettingToEdit
              curEqSetting[index] = eqSettingToEdit
              settings.equalizerSettings = curEqSetting

              if settings.activeEqualizerSetting == eqSettingToEdit {
                settings.activeEqualizerSetting = eqSettingToEdit
              }
            }
            SettingsButtonRow(title: "Delete", actionType: .destructive) {
              isShowDeleteAlert = true
            }.alert(isPresented: $isShowDeleteAlert) {
              Alert(
                title: Text("Delete \(eqSettingNameSaved)?"),
                message: nil,
                primaryButton: .destructive(Text("Delete")) {
                  guard let eqSettingToEdit else { return }
                  var curEqSetting = settings.equalizerSettings
                  guard let index = curEqSetting.firstIndex(of: eqSettingToEdit) else { return }
                  curEqSetting.remove(at: index)
                  settings.equalizerSettings = curEqSetting

                  if settings.activeEqualizerSetting == eqSettingToEdit {
                    settings.activeEqualizerSetting = .off
                  }

                  self.eqSettingToEdit = nil
                },
                secondaryButton: .cancel()
              )
            }
          }

        }, header: "Presets")
      }
    }
    .navigationTitle("Equalizer")
    .navigationBarTitleDisplayMode(.inline)
  }
}

// MARK: - EqualizerSettingsView_Previews

struct EqualizerSettingsView_Previews: PreviewProvider {
  @State
  static var settings = Settings()

  static var previews: some View {
    EqualizerSettingsView().environmentObject(settings)
  }
}

// MARK: - EqualizerPanelView

// cassette §E: the now-playing Equalizer panel. Presented as a slide-up sheet
// from PopupPlayerVC (entry: the player "…" overflow, only when EQ is enabled)
// and backed by the same ambient-backlight treatment as the player, so it reads
// as the same dim room with the cover glowing behind it. Preset chips lead (the
// 90% action); the 10-band sliders fine-tune; the bypass control A/Bs EQ vs
// flat. Every change applies to the playing track in real time. The bypass is
// session-local — the persisted enabled-state is restored on dismiss.
struct EqualizerPanelView: View {
  @ObservedObject
  var ambientModel: AmbientBackdropModel
  var onDone: () -> ()

  @State
  private var active: EqualizerSetting = .off
  @State
  private var gains: [CGFloat] = EqualizerSetting.frequencies.map { _ in 0.0 }
  @State
  private var bypassed = false

  private var labels: [String] {
    EqualizerSetting.frequencies.map { $0 < 1000 ? "\(Int($0))" : "\(Int($0 / 1000))k" }
  }

  /// The built-in preset whose curve matches the active gains, if any (else the
  /// active curve is a hand-tuned "Custom" and no chip is lit).
  private var activePreset: EqualizerPreset? {
    EqualizerPreset.allCases.first { $0.gains == active.gains }
  }

  var body: some View {
    ZStack {
      AmbientCoverBackdrop(model: ambientModel)

      VStack(spacing: 18) {
        HStack {
          Text("Equalizer")
            .font(.headline)
            .foregroundStyle(Color.cassette(.textPrimary))
          Spacer()
          Button("Done", action: onDone)
            .font(.body.weight(.semibold))
            .foregroundStyle(Color.cassette(.textPrimary))
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)

        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 10) {
            ForEach(EqualizerPreset.allCases, id: \.self) { preset in
              presetChip(preset)
            }
          }
          .padding(.horizontal, 20)
        }

        EqualizerView(
          sliderLabels: .constant(labels),
          sliderValues: $gains,
          sliderTintColor: Color.cassette(.textSecondary),
          gradientColors: [Color.cassette(.textTertiary), .clear]
        )
        .padding(.horizontal, 16)
        .opacity(bypassed ? 0.3 : 1)
        .animation(.easeInOut(duration: 0.2), value: bypassed)
        .onChange(of: gains) { _, newGains in
          guard !bypassed else { return }
          applyGains(newGains)
        }

        bypassButton

        Spacer(minLength: 12)
      }
    }
    .preferredColorScheme(.dark)
    .onAppear(perform: load)
    .onDisappear {
      // Undo any A/B bypass: restore the persisted enabled-state on the player.
      appDelegate.player.updateEqualizerEnabled(
        isEnabled: appDelegate.storage.settings.user.isEqualizerEnabled
      )
    }
  }

  private var bypassButton: some View {
    Button {
      bypassed.toggle()
      appDelegate.player.updateEqualizerEnabled(isEnabled: !bypassed)
    } label: {
      HStack(spacing: 8) {
        Image(systemName: bypassed ? "speaker.wave.2" : "speaker.wave.2.fill")
        Text(bypassed ? "Bypassed, hearing it flat" : "Bypass to compare")
      }
      .font(.subheadline.weight(.medium))
      .padding(.horizontal, 18)
      .padding(.vertical, 10)
      .background(bypassed ? Color.cassette(.accentProgress) : Color.cassette(.surfaceElevated))
      .foregroundStyle(bypassed ? Color.cassette(.textOnFill) : Color.cassette(.textPrimary))
      .clipShape(Capsule())
    }
    .buttonStyle(.plain)
  }

  @ViewBuilder
  private func presetChip(_ preset: EqualizerPreset) -> some View {
    let isActive = (activePreset == preset) && !bypassed
    Button { selectPreset(preset) } label: {
      Text(preset.description)
        .font(.subheadline.weight(.medium))
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(isActive ? Color.cassette(.fillSelected) : Color.cassette(.surfaceElevated))
        .foregroundStyle(isActive ? Color.cassette(.textOnFill) : Color.cassette(.textPrimary))
        .clipShape(Capsule())
    }
    .buttonStyle(.plain)
  }

  private func load() {
    active = appDelegate.storage.settings.user.activeEqualizerSetting
    gains = active.gains.map { CGFloat($0) }
    bypassed = false
  }

  private func selectPreset(_ preset: EqualizerPreset) {
    // Keep a stable identity across edits this session so chip highlighting and
    // the active setting stay coherent; only the gains/name follow the preset.
    active = EqualizerSetting(id: active.id, name: preset.description, gains: preset.gains)
    gains = active.gains.map { CGFloat($0) }
    if bypassed {
      bypassed = false
      appDelegate.player.updateEqualizerEnabled(isEnabled: true)
    }
    persistAndApply()
  }

  private func applyGains(_ newGains: [CGFloat]) {
    active.gains = newGains.map { Float($0) }
    if !EqualizerPreset.allCases.contains(where: { $0.gains == active.gains }) {
      active.name = "Custom"
    }
    persistAndApply()
  }

  private func persistAndApply() {
    appDelegate.storage.settings.user.activeEqualizerSetting = active
    appDelegate.player.updateEqualizerSetting(eqSetting: active)
  }
}
