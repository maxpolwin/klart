import Foundation

/// The note the welcome tour offers to open: a real argument with real
/// flaws, long enough for the editor to have something to say.
///
/// Written to trip every lens on purpose. The local checks find the uncited
/// rule of thumb ("12% of revenue"), the hedge-dense risk section and the
/// section tagged `[no-ai]` that must never be read; a model finds the
/// overlapping customer groups (MECE), the decision that leans on a single
/// footfall number (warrant), the unstated assumption about staffing, and
/// the objection nobody raises. The SQL appendix is there because a `#` in
/// a fenced block is a comment, not a heading, and the outline must know.
public enum SampleNote {
    public static let title = "Second location for Nordbrot"

    /// The section the tour asks the editor to read first: the one with the
    /// uncited rule of thumb, which the offline checks flag on their own.
    /// (The hedged risk section is the second offline demo; the hedge rule
    /// wants 120 words before it will speak, and that section has them.)
    public static let readSection = "What the research says"

    public static var readCursorUTF16: Int {
        let ns = english as NSString
        let heading = ns.range(of: "## \(readSection)\n\n")
        guard heading.location != NSNotFound else { return 0 }
        return heading.location + heading.length
    }

    public static let english = """
    # Second location for Nordbrot

    We have run one bakery on Lindenstraße for four years. This note works out \
    whether to open a second one, and where.

    ## Why now

    Saturday queues run out the door and we turn people away between 9 and 11. \
    The unit on Kastanienallee has been empty since spring and the landlord has \
    dropped the asking rent twice. Two competitors closed last year, so the \
    neighbourhood is under-served for the first time since we opened.

    That is the case for moving this year rather than next.

    ## Who we would be selling to

    Four groups of customers:

    - Office workers who want something on the way in
    - Commuters passing the S-Bahn entrance
    - People who buy coffee
    - Locals from the surrounding blocks

    Most of our revenue would come from the first two.

    ## What the research says

    Bakeries in this city live or die on morning footfall, and a second location \
    inside the same delivery radius does not usually cannibalise the first one. \
    Rent above about 12% of revenue is where independents get into trouble.

    I have not actually looked any of this up — this is what I have picked up \
    from other owners over the years.

    ## Notes on the numbers

    We should sign. Rent is €3,400 cold plus roughly €600 warm, though the \
    landlord has been vague about heating. The Lindenstraße shop does about \
    €41,000 a month, of which mornings are a bit over half — and the espresso \
    machine there is due for replacement, which is a separate €7,000 we keep \
    postponing. Break-even at the new unit needs roughly €24,000 a month \
    assuming we staff it the way we staff Lindenstraße. Kastanienallee has more \
    foot traffic than Lindenstraße did in year one. So the rent is defensible, \
    which is really the whole argument. Fit-out is maybe €60,000, maybe more if \
    the ventilation needs redoing, which the previous tenant's setup suggests it \
    might.

    ## Risks

    Margins could suffer somewhat if input costs keep moving. The market seems \
    fairly strong right now but that may not last. Staffing is a concern: we \
    would probably need two more bakers, and it might be hard to find them at \
    the wages we can perhaps afford. Quality might drop a bit while we get \
    established, though it should mostly work out given how the first shop \
    went. The landlord seems reasonable but could possibly change his mind \
    about the fit-out allowance. Kastanienallee may take a while to recover \
    fully, and some of the footfall is likely commuters who never stop. It is \
    arguably too early to know. Nothing here seems fatal, though it is fairly \
    hard to say how the risks would combine if two or three of them landed \
    at once.

    ## The decision

    We sign the Kastanienallee lease in March. Being early to a recovering \
    street beats being right about the rent, and if we wait a year someone else \
    takes the unit.

    ## Fit-out checklist [no-ai]

    Private working list — the editor never sees this section.

    - Call Weber about the ventilation survey
    - Ask the Handwerkskammer about the counter permit
    - Chase the landlord for the heating figure

    ## Appendix: the footfall query

    The counts above come from the sensor export:

    ```sql
    -- # Morning footfall by weekday
    SELECT weekday, AVG(count) AS avg_count
    FROM footfall
    WHERE hour BETWEEN 7 AND 11
    GROUP BY weekday;
    ```

    The `# Morning footfall` line is a SQL comment, not a heading.
    """
}
