// AgentQuestionTests.swift
// OCCTSwiftCADKitTests
//
// Coverage for OCCTSwiftInteraction#62: a `highlight_requests/<id>.json` question that is absent,
// empty, or draws nothing is no question. Its request opens no escalation and lands where a
// request without a question lands. Driven through real request files, so macOS-only like the
// sidecar.

#if os(macOS)

    import Foundation
    import OCCTSwift
    import OCCTSwiftTools
    import Testing

    @testable import OCCTSwiftCADKit

    /// A request's `question` that is no question, named so a failing case reads in the test log.
    struct NoQuestion: Sendable, CustomTestStringConvertible {
        var name: String
        var question: String?
        var testDescription: String { name }

        /// The handled file's `reason` for it: none when absent or empty, as for a label.
        var reason: String? {
            guard let question, !question.isEmpty else { return nil }
            return "question dropped: it has no visible character"
        }
    }

    /// Absent first, so every case is held to what a request without a question does.
    private let noQuestions: [NoQuestion] = [
        NoQuestion(name: "absent", question: nil),
        NoQuestion(name: "empty", question: ""),
        NoQuestion(name: "spaces", question: "   "),
        NoQuestion(name: "tabs and newlines", question: "\t\n\r\n"),
        NoQuestion(name: "zero-width space", question: "\u{200B}"),
        NoQuestion(name: "Hangul filler", question: "\u{3164}"),
        NoQuestion(name: "braille blank", question: "\u{2800}"),
        NoQuestion(name: "a mix of them", question: " \u{200B}\u{3164}\n\u{2800}\u{FEFF}"),
    ]

    /// Questions with a visible character, each of which escalates exactly as sent.
    private let visibleQuestions = [
        "Through-hole or blind pocket?",
        "  padded, as a client may send it  ",
        "zero\u{200B}width inside",
        "\u{2800}x",
        "?",
    ]

    /// A box loaded into a fresh service with its sidecar running, and one face of it.
    @MainActor
    private struct Fixture {
        let service: CADViewportService
        let pick: PickedFaceInfo
        let dir: URL

        init() throws {
            let box = try #require(Shape.box(width: 10, height: 8, depth: 6))
            service = CADViewportService()
            service.load(box, id: "box")
            pick = try #require(service.resolveFacePick(bodyID: "box", triangleIndex: 0))
            dir = try startSidecar(on: service)
        }

        /// Posts one request at `kind` (the face's ordinal for `"face"`) and returns its outcome.
        func send(
            kind: String = "face", question: String?, target: String? = nil,
            label: String? = nil
        ) throws -> HandledOutcome {
            try post(
                HighlightRequestPayload(
                    id: "q", bodyId: "box", kind: kind,
                    index: kind == "face" ? pick.faceIndex : 0, scheme: "replace",
                    question: question, target: target, label: label),
                to: service, in: dir)
        }

        /// Whether the whole body is in the interactive context's selection.
        var wholeBodySelected: Bool {
            service.interactiveContext.selection.subshapes.contains {
                if case .body = $0 { return true }
                return false
            }
        }

        /// Resolves any escalation a failing case opened, then stops the sidecar.
        func tearDown() {
            service.respond(.deferred)
            stopSidecar(on: service, in: dir)
        }
    }

    @Suite("Agent highlight request question")
    struct AgentQuestionTests {

        @MainActor
        @Test(
            "No question, by default target: the attention marker, with its label",
            arguments: noQuestions)
        func noQuestionMarksAttention(noQuestion: NoQuestion) throws {
            let fixture = try Fixture()
            defer { fixture.tearDown() }

            let outcome = try fixture.send(question: noQuestion.question, label: "the datum face")

            #expect(outcome.outcome == "applied")
            #expect(outcome.target == "attention")
            #expect(outcome.reason == noQuestion.reason)
            #expect(fixture.service.pendingEscalation == nil, "no escalation card")
            #expect(fixture.service.agentAttention == .face(fixture.pick))
            #expect(fixture.service.agentAttentionLabel == "the datum face")
            #expect(fixture.service.selection.isEmpty, "the human's selection is untouched")
        }

        @MainActor
        @Test(
            "No question, with target selection: a plain select, a face or a whole body",
            arguments: noQuestions)
        func noQuestionSelects(noQuestion: NoQuestion) throws {
            let face = try Fixture()
            defer { face.tearDown() }
            let faceOutcome = try face.send(question: noQuestion.question, target: "selection")
            #expect(faceOutcome.outcome == "applied")
            #expect(faceOutcome.target == "selection")
            #expect(faceOutcome.reason == noQuestion.reason)
            #expect(face.service.pendingEscalation == nil, "no escalation card")
            #expect(face.service.selection == [.face(face.pick)])
            #expect(face.service.agentAttention == nil)

            // A question on a whole body is rejected; no question on one is an ordinary select.
            let body = try Fixture()
            defer { body.tearDown() }
            let bodyOutcome = try body.send(
                kind: "body", question: noQuestion.question, target: "selection")
            #expect(bodyOutcome.outcome == "applied")
            #expect(bodyOutcome.target == "selection")
            #expect(bodyOutcome.reason == noQuestion.reason)
            #expect(body.wholeBodySelected)
        }

        @MainActor
        @Test(
            "No question on a whole body, by default target: rejected as attention, not escalation",
            arguments: noQuestions)
        func noQuestionWholeBodyIsAttention(noQuestion: NoQuestion) throws {
            let fixture = try Fixture()
            defer { fixture.tearDown() }

            let outcome = try fixture.send(kind: "body", question: noQuestion.question)

            #expect(outcome.outcome == "rejected")
            #expect(outcome.reason?.hasPrefix("attention marks a face, edge or vertex") == true)
            #expect(fixture.service.pendingEscalation == nil)
            #expect(!fixture.wholeBodySelected)
        }

        @MainActor
        @Test(
            "A question with a visible character escalates as sent, whatever target says",
            arguments: visibleQuestions)
        func visibleQuestionEscalates(question: String) throws {
            let fixture = try Fixture()
            defer { fixture.tearDown() }

            let outcome = try fixture.send(question: question, label: "ignored")

            #expect(outcome.outcome == "applied")
            #expect(outcome.target == "selection")
            #expect(outcome.reason == nil)
            let pending = fixture.service.pendingEscalation
            // Scalars, not `String ==`, which would also accept a normalised form.
            #expect(pending?.question.unicodeScalars.elementsEqual(question.unicodeScalars) == true)
            #expect(pending?.entities == [.face(fixture.pick)])
            #expect(fixture.service.selection == [.face(fixture.pick)])
            #expect(fixture.service.agentAttention == nil)

            let body = try Fixture()
            defer { body.tearDown() }
            let bodyOutcome = try body.send(kind: "body", question: question, target: "selection")
            #expect(bodyOutcome.outcome == "rejected")
            #expect(bodyOutcome.reason?.hasPrefix("escalation requests need a face") == true)
            #expect(!body.wholeBodySelected)
        }

        @MainActor
        @Test("A dropped question and a cut label are both reported, the question first")
        func droppedQuestionAndCutLabelShareTheReason() throws {
            let fixture = try Fixture()
            defer { fixture.tearDown() }

            let outcome = try fixture.send(
                question: "\u{200B}", label: String(repeating: "a", count: 81))

            #expect(outcome.target == "attention")
            #expect(
                outcome.reason
                    == "question dropped: it has no visible character; "
                    + "label cut from 81 to 80 characters")
        }
    }

#endif
