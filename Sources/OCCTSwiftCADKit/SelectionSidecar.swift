// SelectionSidecar.swift
// OCCTSwiftCADKit
//
// The wire-format data types for the agent-viewport selection bridge (OCCTSwiftInteraction#16),
// per the ADR at `okf/decisions/agent-viewport-selection-bridge.md` in this repo
// (OCCTSwiftInteraction#17). This file holds only the Codable shapes and the small helpers they
// need; the behaviour that reads and writes them lives in `CADViewportService+AgentBridge.swift`,
// the same data-type/behaviour split as `EscalationRequest.swift` / `+Escalation.swift`.
//
// Every type here is `internal`: the sidecar's public surface is
// `CADViewportService.startSelectionSidecar(directory:)`/`stopSelectionSidecar()` alone, per the
// issue. A host that wants to read these files itself reads the JSON directly against the ADR's
// documented shape, rather than linking this package for its wire types.
//
// macOS-only, gated to match `OCCTSwiftIO.DirectoryWatcher`, the dependency the whole feature is
// built on (Darwin-only: kqueue, and `flock(2)` below).

#if os(macOS)

    import Foundation
    import OCCTSwift

    /// The current schema version this file's writer/reader was built against, per the ADR's
    /// `host.json.schemaVersion`.
    let selectionSidecarSchemaVersion = 1

    /// `selection.json`: the host's current live selection.
    struct SelectionSidecarDocument: Codable, Equatable {
        var revision: Int
        var updatedAt: String
        var selections: [SelectionSidecarEntry]
    }

    /// One entry in `SelectionSidecarDocument.selections`, or a `highlight_requests/<id>.json`
    /// request's target: the two share the same `bodyId`/`kind`/`index` vocabulary by design (the
    /// ADR's own words: "kept consistent with it on purpose").
    struct SelectionSidecarEntry: Codable, Equatable {
        var bodyId: String
        /// `"face" | "edge" | "vertex" | "body"`.
        ///
        /// A plain `String`, not an enum, so a request naming a kind this version doesn't
        /// recognise decodes cleanly and is rejected by the applier with a reason, rather than
        /// failing the whole file's decode.
        var kind: String
        /// Ignored (written as `0`) for `kind == "body"`, per the ADR.
        var index: Int
        var uid: String?
    }

    /// `highlight_requests/<id>.json`: a pending highlight (or escalation) request.
    struct HighlightRequestPayload: Codable, Equatable {
        var id: String
        var bodyId: String
        var kind: String
        var index: Int
        /// The scheme this request combines with the current selection.
        ///
        /// `"replace" | "add" | "remove" | "xor"`, `OCCTSwiftAIS.SelectionScheme`'s own
        /// vocabulary. A plain `String` for the same reason as `kind` above.
        var scheme: String
        var question: String?
    }

    /// `highlight_requests/handled/<id>.json`: the outcome of a processed request.
    struct HandledOutcome: Codable, Equatable {
        /// `"applied" | "rejected" | "superseded"`.
        var outcome: String
        var reason: String?
    }

    /// `host.json`: liveness descriptor, written once at sidecar startup.
    struct HostDescriptor: Codable, Equatable {
        var pid: Int
        var startedAt: String
        var hostName: String
        var hostVersion: String
        var schemaVersion: Int
    }

    extension BRepGraph.GraphUID {
        /// The wire-format string this repo writes into a `uid` field.
        ///
        /// The ADR types `uid` as a plain `String?`, not a nested object. Opaque and never
        /// parsed back: the ADR's own design note says a `uid` reader falls back to
        /// `bodyId`/`kind`/`index` on a miss (a `GraphUID` doesn't survive a graph rebuild or
        /// process restart anyway), so round-tripping this string into a real `GraphUID` is
        /// never needed. The three raw fields, joined, are enough to make two uids from the
        /// same graph instance compare unequal to two different ones without a second encoding
        /// scheme.
        var wireString: String {
            "\(graphID).\(kind).\(counter)"
        }
    }

    /// Holds an exclusive, non-blocking `flock(2)` on a file for as long as this instance lives.
    ///
    /// Per the ADR's `host.lock`: "released by the kernel the instant the host process exits or
    /// crashes, with no explicit unlock needed." A thin wrapper over Darwin's
    /// `open`/`flock`/`close`, not a new locking primitive: `Foundation` has no cross-process
    /// advisory-lock API of its own.
    final class HostLock {
        private var fileDescriptor: Int32 = -1

        /// Creates `url` if absent and takes an exclusive, non-blocking lock on it.
        ///
        /// - Throws: `CADViewportError.sidecarHostAlreadyRunning` if another process already
        ///   holds the lock; `CADViewportError.loadFailed` if the file itself couldn't be
        ///   opened (a permissions problem on `directory`, say).
        func acquire(at url: URL) throws {
            release()
            let fd = open(url.path, O_CREAT | O_RDWR, 0o644)
            guard fd >= 0 else {
                throw CADViewportError.loadFailed("could not open \(url.path) for the host lock")
            }
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
                close(fd)
                throw CADViewportError.sidecarHostAlreadyRunning
            }
            fileDescriptor = fd
        }

        /// Releases the lock and closes the file descriptor.
        ///
        /// Safe to call repeatedly, and safe to call when `acquire(at:)` was never called (or
        /// already failed).
        func release() {
            guard fileDescriptor >= 0 else { return }
            flock(fileDescriptor, LOCK_UN)
            close(fileDescriptor)
            fileDescriptor = -1
        }

        deinit {
            release()
        }
    }

#endif
