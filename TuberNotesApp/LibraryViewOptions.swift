import SwiftUI
import TuberCore
import TuberStore

/// The browser's one snapshot of `LibraryPrefs` — global, not per-folder
/// (spec §7.1's persistent complaint is the evidence that this is one
/// setting). `LibraryBrowserView` owns one instance and every folder view
/// renders from it, so a sort changed inside a subfolder re-orders the views
/// the navigation stack kept alive underneath.
///
/// The store stays the durable value's one writer; this model holds the
/// rendered snapshot and forwards intentions.
@MainActor
@Observable
final class LibraryViewOptionsModel {
    private let library: LibraryStore

    private(set) var prefs: LibraryPrefs = .default

    init(library: LibraryStore) {
        self.library = library
    }

    func load() async {
        prefs = await library.prefs()
    }

    func setViewMode(_ mode: LibraryPrefs.ViewMode) async {
        var next = prefs
        next.viewMode = mode
        await apply(next)
    }

    /// Re-tapping the active key flips the direction (Files/Photos
    /// convention — the spec records it as INFERRED-FROM-PLATFORM, not
    /// observed). A newly selected key starts at its conventional default:
    /// dates newest-first, Name and Type A-first.
    func tapSortKey(_ key: LibrarySortKey) async {
        var next = prefs
        if prefs.sortKey == key {
            next.ascending.toggle()
        } else {
            next.sortKey = key
            next.ascending = Self.defaultAscending(for: key)
        }
        await apply(next)
    }

    nonisolated static func defaultAscending(for key: LibrarySortKey) -> Bool {
        switch key {
        case .dateCreated, .lastModified: return false
        case .name, .type: return true
        }
    }

    /// The snapshot updates first so the choice renders either way; a failed
    /// write costs durability, not the session — a lost sort preference is a
    /// log line, not an alert (the store's own stance on the read side).
    private func apply(_ next: LibraryPrefs) async {
        prefs = next
        do {
            try await library.setPrefs(next)
        } catch {
            CanvasLog.event(.lifecycle, "library prefs write failed: \(error)")
        }
    }
}

/// The four-squares menu in shot 08's structure: **Select Items** first,
/// then Grid ✓ / List, a divider, then the four sort keys with the checkmark
/// and direction chevron on the active key only (UX-11).
struct LibraryViewOptionsPopover: View {
    let options: LibraryViewOptionsModel
    /// Select Items (spec §6.2's entry point). The row renders only where a
    /// caller can actually enter select mode; a menu offering what cannot
    /// happen is lying chrome.
    var onSelectItems: (() -> Void)?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let onSelectItems {
                Button {
                    dismiss()
                    onSelectItems()
                } label: {
                    HStack(spacing: 10) {
                        indicator(checked: false, chevron: nil)
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 15))
                            .foregroundStyle(.white)
                            .frame(width: 24)
                        Text("Select Items")
                            .font(.system(size: 16))
                            .foregroundStyle(.white)
                        Spacer()
                    }
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("library.select")

                Divider()
                    .padding(.vertical, 6)
            }

            viewModeRow(.grid, symbol: "square.grid.2x2", title: "Grid")
            viewModeRow(.list, symbol: "list.bullet", title: "List")

            Divider()
                .padding(.vertical, 6)

            sortRow(.dateCreated, title: "Date Created")
            sortRow(.lastModified, title: "Last Modified")
            sortRow(.name, title: "Name")
            sortRow(.type, title: "Type")
        }
        .padding(12)
        .frame(width: 280)
        .presentationCompactAdaptation(.popover)
        .accessibilityIdentifier("library.viewoptions.menu")
    }

    private func viewModeRow(
        _ mode: LibraryPrefs.ViewMode,
        symbol: String,
        title: String
    ) -> some View {
        let active = options.prefs.viewMode == mode
        return Button {
            // A mode change is terminal; the menu closes with it.
            Task { await options.setViewMode(mode) }
            dismiss()
        } label: {
            HStack(spacing: 10) {
                indicator(checked: active, chevron: nil)
                Image(systemName: symbol)
                    .font(.system(size: 15))
                    .foregroundStyle(.white)
                    .frame(width: 24)
                Text(title)
                    .font(.system(size: 16))
                    .foregroundStyle(.white)
                Spacer()
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("library.viewoptions.\(mode.rawValue)")
    }

    private func sortRow(_ key: LibrarySortKey, title: String) -> some View {
        let active = options.prefs.sortKey == key
        return Button {
            // Stays open: re-tapping the active key is the direction toggle,
            // and closing on the first tap would hide that affordance.
            Task { await options.tapSortKey(key) }
        } label: {
            HStack(spacing: 10) {
                indicator(
                    checked: active,
                    chevron: active
                        ? (options.prefs.ascending ? "chevron.up" : "chevron.down")
                        : nil
                )
                Text(title)
                    .font(.system(size: 16))
                    .foregroundStyle(.white)
                Spacer()
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("library.sort.\(key.rawValue)")
    }

    /// The leading indicator column: check + direction chevron on the active
    /// sort key, check alone on the active view mode, blank space otherwise
    /// so titles align.
    private func indicator(checked: Bool, chevron: String?) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "checkmark")
                .font(.system(size: 12, weight: .semibold))
                .opacity(checked ? 1 : 0)
            Image(systemName: chevron ?? "chevron.down")
                .font(.system(size: 12, weight: .semibold))
                .opacity(chevron == nil ? 0 : 1)
        }
        .foregroundStyle(.white)
        .frame(width: 36, alignment: .leading)
    }
}

/// The funnel chip as a menu: All / Documents / Folders (spec §7.2). The
/// label reflects the active choice and reads blue when a filter is applied.
/// Session-scoped — the choice lives in the folder's listing model and
/// nothing is persisted, because GoodNotes evidence on filter persistence
/// is absent.
struct LibraryFilterChip: View {
    let model: FolderListingModel

    var body: some View {
        Menu {
            option(.all, title: "All")
            option(.documents, title: "Documents")
            option(.folders, title: "Folders")
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.system(size: 15))
                Text(label)
                    .font(.system(size: 17))
            }
            .foregroundStyle(model.filter == .all ? Color.white : Color.blue)
        }
        .accessibilityIdentifier("library.filter")
    }

    private var label: String {
        switch model.filter {
        case .all: return "All"
        case .documents: return "Documents"
        case .folders: return "Folders"
        }
    }

    private func option(
        _ filter: FolderListingModel.ItemFilter,
        title: String
    ) -> some View {
        Button {
            model.filter = filter
        } label: {
            if model.filter == filter {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
        .accessibilityIdentifier("library.filter.\(filter.rawValue)")
    }
}
