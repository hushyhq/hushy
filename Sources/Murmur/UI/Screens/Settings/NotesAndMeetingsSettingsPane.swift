import SwiftUI

/// The frozen part of Settings, shown only while Advanced → "Notes and meetings (preview)" is on:
/// everything about recording a call into a note (`MeetingsSettingsPane`), then the voices Hushy
/// remembers for labelling speakers (`VoicesListView`, which was its own pane).
struct NotesAndMeetingsSettingsPane: View {
    @Binding var showTune: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xl) {
            MeetingsSettingsPane()
            VoicesListView(showTune: $showTune)
        }
    }
}
