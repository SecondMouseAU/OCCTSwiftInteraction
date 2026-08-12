import OCCTSwift
import Testing

@testable import OCCTSwiftTools

@Suite("ShapeMeasurements")
struct ShapeMeasurementsTests {

    @Test func t_metadataIncludesMeasurementsWhenRequested() {
        guard let box = Shape.box(width: 1, height: 1, depth: 1) else {
            Issue.record("Shape.box returned nil")
            return
        }
        let (_, metaOff) = CADFileLoader.shapeToBodyAndMetadata(
            box, id: "off", color: .init(0.7, 0.7, 0.7, 1.0)
        )
        let (_, metaOn) = CADFileLoader.shapeToBodyAndMetadata(
            box, id: "on", color: .init(0.7, 0.7, 0.7, 1.0),
            includeMeasurements: true
        )
        #expect(metaOff?.measurements == nil, "off by default")
        if let m = metaOn?.measurements {
            #expect(m.faceAreas.count == 6)
            #expect(abs(m.totalFaceArea - 6.0) < 1e-6, "unit cube has 6 mm² total")
        } else {
            Issue.record("includeMeasurements:true should populate metadata.measurements")
        }
    }
}
