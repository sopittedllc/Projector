//
//  AudioStemGrouping.swift
//  Projector
//
//  Reading the stem role out of a delivery filename, so a batch of reels
//  lands on lanes that mean something.
//

import Foundation

/// The role a stem plays in a mix, as post houses abbreviate it in filenames.
///
/// The raw value is the short form the lane is named after. Longer spellings
/// map onto the same case through ``AudioStemGrouping``'s alias table, so a
/// delivery that says `DIALOGUE` on one reel and `DX` on the next still groups
/// as one stem.
enum AudioStemRole: String, Sendable, CaseIterable {
    case dialogue = "DX"
    case music = "MX"
    case effects = "FX"
    case backgrounds = "BG"
    case foley = "FOLEY"
    case musicAndEffects = "M&E"
    case voiceOver = "VO"
    case group = "GRP"
    case nats = "NAT"
    case optical = "OPT"
    case printMaster = "PM"
    case mix = "MIX"
}

/// The stem a filename declares: one role, or several combined in one file.
///
/// A combined stem is ordinary - `_DX_FX` is a single file carrying dialogue
/// and effects together - so a stem is a list of roles rather than one role.
struct AudioStemLabel: Sendable, Equatable {

    /// The roles this stem carries, in the order the filename wrote them.
    let roles: [AudioStemRole]

    /// Identity for grouping, independent of the order the roles were written.
    ///
    /// `_DX_FX` and `_FX_DX` are the same stem delivered by two people with
    /// different habits, and they belong on the same lane.
    var key: String {
        roles.map(\.rawValue).sorted().joined(separator: "+")
    }

    /// What the lane is called: `DX FX`, `MX`, `M&E`.
    var displayName: String {
        roles.map(\.rawValue).joined(separator: " ")
    }
}

/// A set of dropped files that belong on one lane.
struct AudioStemGroup: Sendable {

    /// The stem the files share, or `nil` when the filename declared none.
    let stem: AudioStemLabel?

    /// The files, in reel order when the group holds more than one.
    let urls: [URL]
}

/// Sorts a dropped batch of audio files into the lanes they actually want.
///
/// ## The problem
///
/// A reel-based delivery arrives as one file per reel per stem: five reels of
/// a feature hand over five dialogue-and-effects files and five music files.
/// Giving each dropped file its own lane produces ten lanes holding one clip
/// each, when the material has two stems that happen to be cut into reels.
/// The reels are sequential, so nine of those lanes are mostly empty and the
/// timeline reads as a staircase instead of as two continuous stems.
///
/// ## What the filenames give us
///
/// The reel number varies, the descriptive middle of the name can vary too -
/// a reel carrying an end-title song often says so - but the stem suffix is
/// the one part a delivery keeps constant, because it is the part that tells
/// a mixer what is in the file. So the stem is read from the *end* of the
/// name and everything before it is ignored, which groups reels whose only
/// common ground is that suffix.
///
/// ## Reading the end of the name
///
/// Tokens are taken from the end while they are either a known role or noise
/// (a reel number, a channel layout, a version). The walk stops at the first
/// token that is neither, which is what keeps a project code or a session
/// name from being read as a stem. A run with no role in it is not a stem.
enum AudioStemGrouping {

    // MARK: - Vocabulary

    /// Spellings that name a role, uppercased. Every raw value appears here too.
    private static let roleAliases: [String: AudioStemRole] = [
        "DX": .dialogue, "DIA": .dialogue, "DIAL": .dialogue,
        "DIALOG": .dialogue, "DIALOGUE": .dialogue, "DLG": .dialogue,
        "MX": .music, "MUS": .music, "MUSIC": .music,
        "FX": .effects, "SFX": .effects, "EFX": .effects, "EFFECTS": .effects,
        "BG": .backgrounds, "BGS": .backgrounds,
        "AMB": .backgrounds, "AMBIENCE": .backgrounds, "AMBIENCES": .backgrounds,
        "FOL": .foley, "FOLEY": .foley,
        "ME": .musicAndEffects, "M&E": .musicAndEffects, "MANDE": .musicAndEffects,
        "VO": .voiceOver, "NAR": .voiceOver, "NARR": .voiceOver, "NARRATION": .voiceOver,
        "GRP": .group, "WALLA": .group, "LOOPGROUP": .group,
        "NAT": .nats, "NATS": .nats,
        "OPT": .optical,
        "PM": .printMaster, "PRINT": .printMaster, "MASTER": .printMaster,
        "MIX": .mix, "FULLMIX": .mix
    ]

    /// Tokens that routinely trail a stem without changing which stem it is.
    ///
    /// Skipping them lets `_DX_STEM`, `_DX_51` and `_DX_v2` all read as `DX`.
    /// Noise alone never makes a stem - the run still has to contain a role -
    /// so a file called `Stereo Bounce` is not silently filed as a stem.
    private static let noiseTokens: Set<String> = [
        "STEM", "STEMS", "STEREO", "MONO", "LTRT", "LT", "RT",
        "51", "71", "20", "20B", "24B", "16B",
        "24BIT", "16BIT", "32BIT", "48K", "96K", "192K",
        "REEL", "R", "FINAL", "NEW", "COPY"
    ]

    /// Characters that separate one token from the next in a filename.
    ///
    /// `&` is deliberately absent so `M&E` survives as a single token.
    private static let separators = CharacterSet(charactersIn: "_- .+()[],")

    // MARK: - Reading a filename

    /// The stem a single file declares, or `nil` when it declares none.
    ///
    /// - Parameter url: The audio file. Only its name is read; the file is
    ///   never opened.
    /// - Returns: The stem, or `nil` when the end of the name holds no role.
    static func stem(for url: URL) -> AudioStemLabel? {
        let base = url.deletingPathExtension().lastPathComponent
        let tokens = base
            .components(separatedBy: separators)
            .map { $0.uppercased() }
            .filter { !$0.isEmpty }

        var reversedRoles: [AudioStemRole] = []
        for token in tokens.reversed() {
            if let role = roleAliases[token] {
                reversedRoles.append(role)
                continue
            }
            if isNoise(token) { continue }
            break
        }

        guard !reversedRoles.isEmpty else { return nil }

        // Written order, with repeats dropped: `PRINT MASTER` is two spellings
        // of one role and should not name a lane `PM PM`.
        var roles: [AudioStemRole] = []
        for role in reversedRoles.reversed() where !roles.contains(role) {
            roles.append(role)
        }
        return AudioStemLabel(roles: roles)
    }

    /// Whether a token is trailing detail rather than part of the stem.
    ///
    /// - Parameter token: An uppercased filename token.
    /// - Returns: `true` for a known noise word, a pure number (reel and part
    ///   numbering) or a version marker such as `V2`.
    private static func isNoise(_ token: String) -> Bool {
        if noiseTokens.contains(token) { return true }
        if token.allSatisfy(\.isNumber) { return true }
        if token.first == "V", token.dropFirst().allSatisfy(\.isNumber), token.count > 1 {
            return true
        }
        return false
    }

    // MARK: - Grouping a batch

    /// Groups a dropped batch so files sharing a stem share a lane.
    ///
    /// Files whose names declare no stem are left ungrouped - each gets its
    /// own group, which is the one-lane-per-file behaviour that has always
    /// applied to material this can say nothing about.
    ///
    /// - Parameter urls: The dropped audio files, in the order they arrived.
    /// - Returns: Groups in the order their stem first appeared, each holding
    ///   its files in reel order.
    static func groups(for urls: [URL]) -> [AudioStemGroup] {
        var keysInOrder: [String] = []
        var stems: [String: AudioStemLabel?] = [:]
        var files: [String: [URL]] = [:]

        for (index, url) in urls.enumerated() {
            let label = stem(for: url)
            // An ungrouped file keys on its own position, so it never joins
            // another file's lane. The prefix cannot collide with a stem key,
            // which is only ever role raw values joined by "+".
            let key = label?.key ?? "ungrouped \(index)"
            if files[key] == nil {
                keysInOrder.append(key)
                stems[key] = label
            }
            files[key, default: []].append(url)
        }

        return keysInOrder.map { key in
            let urls = files[key] ?? []
            // Sorted the way the Finder sorts, so reel 2 precedes reel 10 and
            // sequential placement of files without timecode follows the reels.
            let ordered = urls.count > 1
                ? urls.sorted {
                    $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
                }
                : urls
            return AudioStemGroup(stem: stems[key] ?? nil, urls: ordered)
        }
    }
}
