import CoreGraphics
import TuberModel

/// The one place a paper template becomes marks.
///
/// Pure geometry into a context whose CTM is **already page space** — origin
/// top-left, y down, units page points, exactly what `StaticLayerRenderer`
/// establishes for the composite and for the lens. It fills no background,
/// reads nothing, touches no file, and allocates nothing beyond the path it
/// builds.
///
/// **A name resolved to pixels, never a stored colour.** Every number and every
/// colour below is a constant this build owns; nothing durable says how far
/// apart the rules are (`Contract.proposed.md` A16). That is also the whole of
/// the dark-mode hook: when an appearance arrives it changes `markColor` here
/// and joins the render request and the cache key, and no document written
/// before it has to change. An unread `appearance` field today would be the
/// placeholder `Contract.md` — Forbidden patterns bans, so there is none.
///
/// **Procedural rather than a paper image**, for two reasons that outlive the
/// convenience. Pages differ in size within one document, so one image could
/// not serve both an imported worksheet and the canonical page beside it. And
/// because the lens re-*strokes* the ruling at the settled scale rather than
/// resampling a raster of it, ruled paper is genuinely resolution-independent
/// at any zoom — a property a pre-rendered image could not have at all.
///
/// It imports CoreGraphics and not UIKit deliberately: nothing here is a view,
/// a layer, or frame-frequency work. `ContractStructureTests` holds it to that.
enum PaperTemplateRenderer {

    /// Every measurement a template is drawn from, in **absolute page points**,
    /// measured from the page-space origin at the top-left
    /// (`Contract.proposed.md` A17).
    ///
    /// **Never a fraction of the page.** Mixed geometry is the normal state of
    /// an annotated import — a landscape worksheet sits beside a canonical
    /// appended page — and ruling that scaled with the page would put different
    /// line spacings on facing pages of one notebook. Absolute spacing means a
    /// wider page gets more columns at *the same* spacing, which is what paper
    /// does.
    ///
    /// These are the build's numbers and Phillip's to retune; each says why it
    /// is what it is, because "24" is otherwise unfalsifiable.
    enum Metrics {
        /// 24 pt = 1/3 inch, the width of US wide-ruled paper (8.7 mm ≈ 24.7
        /// pt) rounded to a third of an inch. Wide rather than college-ruled
        /// (≈ 20 pt) because handwriting with a stylus on glass runs larger
        /// than handwriting with a pen on paper.
        static let ruleSpacing: Double = 24

        /// 18 pt = 1/4 inch, the quad-ruled square every engineering pad uses.
        /// Deliberately not equal to `ruleSpacing`: a grid is read in both axes
        /// at once, so its cell wants to be squarer and smaller than the line
        /// pitch that only has to hold one row of writing.
        static let gridSpacing: Double = 18

        /// The same lattice as `grid`, minus the lines. One number rather than
        /// two so that switching between them moves nothing on the page — the
        /// dots land exactly where the intersections were.
        static let dotSpacing: Double = 18

        /// 0.6 pt, so a dot is 1.2 pt across — about two and a half device
        /// pixels at the level of detail a page opens at. Large enough to be a
        /// mark and small enough to stay a dot rather than becoming a blob.
        static let dotRadius: Double = 0.6

        /// 0.5 pt: one device pixel at the 2× display every iPad has, at the
        /// scale a page opens at. A rule wider than a hairline reads as a
        /// drawn line rather than as printed ruling, and competes with ink.
        static let ruleWidth: Double = 0.5

        /// 1 inch of header above the first rule of a `lined` page, the paper
        /// convention. It applies to `lined` alone: `grid` and `dotted` are
        /// lattices, and a lattice offset from one edge by a margin no other
        /// edge has stops being uniform — which is the one thing a lattice is
        /// for.
        static let topMargin: Double = 72
    }

    /// A desaturated blue-grey: printed ruling, not drawn ink. It has to
    /// recede under a black stroke rather than compete with it, which is the
    /// judgement a device makes and this constant only proposes.
    ///
    /// Opaque rather than a tinted alpha, so a fully covered pixel is exactly
    /// this colour and a test can say so.
    private static let markColor = CGColor(srgbRed: 0.58, green: 0.65, blue: 0.75, alpha: 1)

    /// Adds one template's marks to `context`, in page points.
    ///
    /// `clip` is the page-space rect the caller will actually show: the base
    /// composite passes the whole page, and the lens passes the visible rect.
    /// **Only marks intersecting it are emitted at all** — a lens two hundred
    /// points tall on a long page must not stroke the thousand rules above it
    /// and rely on CoreGraphics to throw them away.
    static func draw(
        _ template: PageTemplate,
        in context: CGContext,
        pageSize: CGSize,
        clippedTo clip: CGRect
    ) {
        let width = Double(pageSize.width)
        let height = Double(pageSize.height)
        let visible = clip.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        // `blank` has no marks anywhere, and a clip that misses the page has
        // none inside it. Either way the graphics state is not even saved: the
        // blank page is the case that must cost nothing, and this function is
        // not going to be the one that breaks that.
        guard template != .blank, !visible.isNull, !visible.isEmpty else { return }

        context.saveGState()
        context.setFillColor(Self.markColor)
        context.beginPath()
        switch template {
        case .blank:
            // Unreachable — guarded above. Spelled as a case rather than as a
            // `default` so that adding a member to `PageTemplate` is a compile
            // error here, which is the promise that enum's own doc makes.
            break
        case .lined:
            addRows(
                to: context, firstAt: Metrics.topMargin, spacing: Metrics.ruleSpacing,
                width: width, height: height, visible: visible
            )
        case .grid:
            addRows(
                to: context, firstAt: Metrics.gridSpacing, spacing: Metrics.gridSpacing,
                width: width, height: height, visible: visible
            )
            addColumns(
                to: context, firstAt: Metrics.gridSpacing, spacing: Metrics.gridSpacing,
                width: width, height: height, visible: visible
            )
        case .dotted:
            addDots(
                to: context, spacing: Metrics.dotSpacing, radius: Metrics.dotRadius,
                width: width, height: height, visible: visible
            )
        }
        context.fillPath()
        context.restoreGState()
    }

    // MARK: - The marks themselves

    /// Horizontal rules, full page width, at `firstAt + k × spacing`.
    ///
    /// A rule is a **filled rect** rather than a stroked line, and that is not
    /// a style choice: a stroke centres itself on its path, so a half-point
    /// rule at an integral coordinate straddles a pixel boundary and lands as
    /// two grey rows at every scale. Filled from the rule's own y downward, it
    /// is one crisp row wherever the scale makes it whole — which is the
    /// property the lens exists to deliver.
    private static func addRows(
        to context: CGContext,
        firstAt first: Double,
        spacing: Double,
        width: Double,
        height: Double,
        visible: CGRect
    ) {
        for y in stops(
            firstAt: first, spacing: spacing, extent: height, thickness: Metrics.ruleWidth,
            from: Double(visible.minY), to: Double(visible.maxY)
        ) {
            context.addRect(CGRect(x: 0, y: y, width: width, height: Metrics.ruleWidth))
        }
    }

    /// Vertical rules, full page height, at `firstAt + k × spacing`.
    private static func addColumns(
        to context: CGContext,
        firstAt first: Double,
        spacing: Double,
        width: Double,
        height: Double,
        visible: CGRect
    ) {
        for x in stops(
            firstAt: first, spacing: spacing, extent: width, thickness: Metrics.ruleWidth,
            from: Double(visible.minX), to: Double(visible.maxX)
        ) {
            context.addRect(CGRect(x: x, y: 0, width: Metrics.ruleWidth, height: height))
        }
    }

    /// One dot at each lattice intersection, centred on it.
    ///
    /// A dot is placed by its centre, so the first lattice line is a whole
    /// `dotSpacing` in from the page edge and no dot is ever half off the
    /// page — a clipped dot at the margin reads as damage rather than as
    /// paper.
    private static func addDots(
        to context: CGContext,
        spacing: Double,
        radius: Double,
        width: Double,
        height: Double,
        visible: CGRect
    ) {
        // Held as the stride sequence rather than as an array of positions: it
        // is a value, re-walked per row for nothing, and this function
        // allocates only its path.
        let columns = stops(
            firstAt: spacing, spacing: spacing, extent: width, thickness: 0,
            from: Double(visible.minX) - radius, to: Double(visible.maxX) + radius,
            inset: radius
        )
        for y in stops(
            firstAt: spacing, spacing: spacing, extent: height, thickness: 0,
            from: Double(visible.minY) - radius, to: Double(visible.maxY) + radius,
            inset: radius
        ) {
            for x in columns {
                context.addEllipse(
                    in: CGRect(
                        x: x - radius, y: y - radius, width: radius * 2, height: radius * 2
                    )
                )
            }
        }
    }

    /// The positions of one axis's marks that fall inside `[lower, upper]` and
    /// inside the page.
    ///
    /// The first index is computed rather than walked to, so a lens deep into a
    /// long page costs the rules it shows and not the ones above them.
    ///
    /// `inset` keeps a mark placed by its centre — a dot — wholly on the page;
    /// `thickness` does the same for a mark placed by its leading edge.
    private static func stops(
        firstAt first: Double,
        spacing: Double,
        extent: Double,
        thickness: Double,
        from lower: Double,
        to upper: Double,
        inset: Double = 0
    ) -> StrideThrough<Double> {
        // A spacing of zero would be an infinite loop rather than a dense page.
        // It cannot happen — these are constants — so it is a trap and not a
        // clamp (`Contract.md`: invalid states fail loud).
        precondition(spacing > 0, "a template spacing of \(spacing) points is not a spacing")

        // The first mark at or after `lower`, and the last at or before both
        // `upper` and the page's own edge. `stride(from:through:by:)` over an
        // empty range yields nothing, which is the whole of "a page shorter
        // than one rule spacing draws zero rules".
        let firstIndex = max(0.0, ((lower - thickness - first) / spacing).rounded(.up))
        let start = first + firstIndex * spacing
        let end = min(upper, extent - thickness - inset)
        return stride(from: start, through: end, by: spacing)
    }
}
