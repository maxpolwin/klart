# Second location for Nordbrot

We have run one bakery on Lindenstraße for four years. This note works out
whether to open a second one, and where.

## Why now

Saturday queues run out the door and we turn people away between 9 and 11.
The unit on Kastanienallee has been empty since spring and the landlord has
dropped the asking rent twice. Two competitors closed last year, so the
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

Bakeries in this city live or die on morning footfall, and a second location
inside the same delivery radius does not usually cannibalise the first one.
Rent above about 12% of revenue is where independents get into trouble.

I have not actually looked any of this up — this is what I have picked up
from other owners over the years.

## Notes on the numbers

We should sign. Rent is €3,400 cold plus roughly €600 warm, though the
landlord has been vague about heating. The Lindenstraße shop does about
€41,000 a month, of which mornings are a bit over half — and the espresso
machine there is due for replacement, which is a separate €7,000 we keep
postponing. Break-even at the new unit needs roughly €24,000 a month
assuming we staff it the way we staff Lindenstraße. Kastanienallee has more
foot traffic than Lindenstraße did in year one. So the rent is defensible,
which is really the whole argument. Fit-out is maybe €60,000, maybe more if
the ventilation needs redoing, which the previous tenant's setup suggests it
might.

## Risks

Margins could suffer somewhat if input costs keep moving. The market seems
fairly strong right now but that may not last. Staffing is a concern.
Quality might drop a bit while we get established, though it should mostly
work out given how the first shop went.

## The decision

We sign the Kastanienallee lease in March. Being early to a recovering
street beats being right about the rent, and if we wait a year someone else
takes the unit.

## Fit-out checklist [no-ai]

Private working list — the coach should never see this section.

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
