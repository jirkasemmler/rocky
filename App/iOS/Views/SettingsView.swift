import SwiftUI
import RockyCore

/// PRD screen "Nastavení": training days, reminder time + escalation limit, intervals,
/// voice (Czech system voice, rate, volume, tips), vibration, watch sound.
struct SettingsView: View {
    @Environment(TrainingStore.self) private var store
    @State private var draft = Settings.default
    @State private var loaded = false
    @State private var previewSpeech = SpeechService(audio: nil)
    private let voices = SpeechService.czechVoices()

    var body: some View {
        Form {
            Section {
                ForEach(Weekday.mondayFirst, id: \.self) { day in
                    Toggle(day.label, isOn: Binding(
                        get: { draft.trainingDays.contains(day) },
                        set: { on in
                            if on {
                                draft.trainingDays.insert(day)
                            } else if draft.trainingDays.count > 1 {
                                draft.trainingDays.remove(day)
                            }
                        }
                    ))
                }
            } header: {
                Text("Tréninkové dny")
            } footer: {
                Text("Doporučeno 3× týdně s dnem volna mezi tréninky (výchozí Po / St / Pá).")
            }

            Section {
                DatePicker("Připomenutí", selection: timeBinding(\.reminderTime), displayedComponents: .hourAndMinute)
                DatePicker("Nejpozději", selection: timeBinding(\.latestEscalation), displayedComponents: .hourAndMinute)
                Toggle("Stupňovat i v běžné tréninkové dny", isOn: $draft.escalateOnPlannedDays)
            } header: {
                Text("Připomínky")
            } footer: {
                Text("Když máš dluh, připomínky chodí každý den, i ve dny volna: v nastavený čas, po hodině a po dvou, nejpozději v čas „Nejpozději“. Přepínač se týká jen běžných tréninkových dnů bez dluhu.")
            }

            Section("Intervaly") {
                Stepper("Cvik: \(draft.intervals.workSeconds) s", value: $draft.intervals.workSeconds, in: 20...90, step: 5)
                Stepper("Pauza: \(draft.intervals.restSeconds) s", value: $draft.intervals.restSeconds, in: 10...60, step: 5)
                Stepper("Pauza mezi koly: \(draft.intervals.roundRestSeconds) s",
                        value: $draft.intervals.roundRestSeconds, in: 30...180, step: 15)
                Stepper("Kola: \(draft.intervals.rounds)", value: $draft.intervals.rounds, in: 1...5)
                Stepper("Rozcvička: \(Format.clock(TimeInterval(draft.intervals.warmUpSeconds)))",
                        value: $draft.intervals.warmUpSeconds, in: 0...600, step: 30)
                LabeledContent("Protažení", value: "\(Format.clock(TimeInterval(IntervalSettings.stretchSeconds))) (vždy)")
            }

            Section {
                Toggle("Hlasové pokyny", isOn: $draft.voiceEnabled)
                Picker("Hlas", selection: $draft.voiceIdentifier) {
                    Text("Výchozí (Zuzana)").tag(String?.none)
                    ForEach(voices) { voice in
                        Text("\(voice.name) · \(voice.quality)").tag(Optional(voice.id))
                    }
                }
                VStack(alignment: .leading) {
                    Text("Rychlost řeči")
                    Slider(value: $draft.speechRate, in: 0.3...0.7)
                }
                VStack(alignment: .leading) {
                    Text("Hlasitost")
                    Slider(value: $draft.volume, in: 0...1)
                }
                Toggle("Tipy na techniku", isOn: $draft.techniqueTipsEnabled)
                Button("Přehrát ukázku") {
                    previewSpeech.rate = draft.speechRate
                    previewSpeech.volume = draft.volume
                    previewSpeech.preview(identifier: draft.voiceIdentifier)
                }
            } header: {
                Text("Hlas")
            } footer: {
                if voices.isEmpty {
                    Text("Žádný český hlas není nainstalovaný. Přidej ho v Nastavení iOS → Zpřístupnění → Předčítání → Hlasy → Čeština.")
                } else {
                    Text("Kvalitnější hlas (Vylepšený/Prémiový) lze stáhnout v Nastavení iOS → Zpřístupnění → Předčítání → Hlasy.")
                }
            }

            Section {
                Toggle("Rockyho hlášky", isOn: $draft.rockyLinesEnabled)
                TextField("Oslovení (5. pád, např. Jiří)", text: $draft.address)
                    .textInputAutocapitalization(.words)
                    .disabled(!draft.rockyLinesEnabled)
            } header: {
                Text("Rocky")
            } footer: {
                Text("Vtipné a motivační hlášky během tréninku, v připomínkách a na úvodní obrazovce. Pokyny ke cvikům a odpočet zůstávají vždy stručné. Bez oslovení říká Rocky „šampione“.")
            }

            Section("Vibrace a hodinky") {
                Toggle("Vibrace", isOn: $draft.vibrationEnabled)
                Toggle("Hlas i z hodinek", isOn: $draft.watchSoundEnabled)
            }

            ServerSettingsSection()

            Section("Soukromí") {
                Text("Data zůstávají v tomto zařízení (a v hodinkách), případně na tvém vlastním serveru. Žádný účet, žádná telemetrie.")
                    .font(.footnote)
            }
        }
        .navigationTitle("Nastavení")
        .onAppear {
            guard !loaded else { return }
            loaded = true
            draft = store.settings
        }
        .onChange(of: draft) { _, newValue in
            store.updateSettings(newValue)
        }
    }

    private func timeBinding(_ keyPath: WritableKeyPath<Settings, TimeOfDay>) -> Binding<Date> {
        let calendar = store.calendar
        return Binding(
            get: { draft[keyPath: keyPath].date(on: Date(), calendar: calendar) },
            set: { draft[keyPath: keyPath] = TimeOfDay(date: $0, calendar: calendar) }
        )
    }
}
