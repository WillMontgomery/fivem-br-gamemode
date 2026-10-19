-- The data center's main gate (#420), Season 2: WRITTEN BY tools/dcgate_parts.py
-- FROM THE MAP'S DOOR TABLE AND THE GATE KIT, NOT EDITED. The three lanes' 24
-- bi-fold leaves and 3 crash arms the gamemode registers, locks and opens, each
-- lane's box (the ground a closing gate waits on) and the six lane readers.
--
--   leads    x, y, z, h: the placed origin (the hinge axis, leaf mid-height) and
--            heading; sense: +1 opens by +theta about local +z, -1 by -theta
--   follows  rides its lead (`lead`, an index into leads) at the knuckle
--            (ox, oy, oz), turned `turn` times its lead's turn: the bi-fold
--   arm      turns about local +`axis` by `sense` times the raise
--   box      a center, the lane's direction (ux, uy) from the outer gate to the
--            inner one, half its length and width, and the grade under it
--
-- To change a part, fix the map and run the tool again:
--     py tools/dcgate_parts.py <brdc_site_doors.json> <kit_gate_doors.json>
-- docs/dcgate.md says who reads these rows and why.
--
-- Source: brdc_site_doors.json, sha256 7bf342b050c9b5ca1009109790b4196b52c79105afffd6702e1db86b429715ef
-- Source: kit_gate_doors.json, sha256 53c32c8d99920444c8449ae3668a74175aba31bac6e1d2315b9f5cf24cad1916

BR = BR or {}
BR.Config = BR.Config or {}
BR.Config.DcGate = BR.Config.DcGate or {}

BR.Config.DcGate.parts = {
    center = { x = 2433.634, y = 1380.3364, z = 45.6245 }, radius = 19.15,
    lanes = {
        {
            lane = 1,
            box = { x = 2432.643, y = 1372.99, ux = -1.0, uy = 0.0, halfLength = 14.6187, halfWidth = 2.095, zLow = 44.38, zHigh = 44.532 },
            leads = {
                { id = 'gate.lane1.outer.lead_l', model = 'brdc_bifold_lead_l', x = 2445.0, y = 1375.085, z = 45.6242, h = 270.0, sense = 1 },
                { id = 'gate.lane1.outer.lead_r', model = 'brdc_bifold_lead_r', x = 2445.0, y = 1370.895, z = 45.6242, h = 270.0, sense = -1 },
                { id = 'gate.lane1.inner.lead_l', model = 'brdc_bifold_lead_l', x = 2419.09, y = 1370.895, z = 45.6242, h = 90.0, sense = 1 },
                { id = 'gate.lane1.inner.lead_r', model = 'brdc_bifold_lead_r', x = 2419.09, y = 1375.085, z = 45.6242, h = 90.0, sense = -1 },
            },
            follows = {
                { id = 'gate.lane1.outer.follow_l', model = 'brdc_bifold_follow_l', x = 2444.96, y = 1374.02, z = 45.6242, h = 270.0, lead = 1, ox = 1.065, oy = -0.04, oz = 0.0, turn = -2 },
                { id = 'gate.lane1.outer.follow_r', model = 'brdc_bifold_follow_r', x = 2444.96, y = 1371.96, z = 45.6242, h = 270.0, lead = 2, ox = -1.065, oy = -0.04, oz = 0.0, turn = -2 },
                { id = 'gate.lane1.inner.follow_l', model = 'brdc_bifold_follow_l', x = 2419.13, y = 1371.96, z = 45.6242, h = 90.0, lead = 3, ox = 1.065, oy = -0.04, oz = 0.0, turn = -2 },
                { id = 'gate.lane1.inner.follow_r', model = 'brdc_bifold_follow_r', x = 2419.13, y = 1374.02, z = 45.6242, h = 90.0, lead = 4, ox = -1.065, oy = -0.04, oz = 0.0, turn = -2 },
            },
            arm = { id = 'gate.lane1.outer_arm.arm', model = 'brdc_croparm_arm', x = 2447.0117, y = 1375.57, z = 45.452, h = 270.0, axis = 'y', sense = -1 },
        },
        {
            lane = 2,
            box = { x = 2432.643, y = 1380.305, ux = -1.0, uy = 0.0, halfLength = 14.6187, halfWidth = 2.1, zLow = 44.38, zHigh = 44.532 },
            leads = {
                { id = 'gate.lane2.outer.lead_l', model = 'brdc_bifold_lead_l', x = 2445.0, y = 1382.405, z = 45.6242, h = 270.0, sense = 1 },
                { id = 'gate.lane2.outer.lead_r', model = 'brdc_bifold_lead_r', x = 2445.0, y = 1378.205, z = 45.6242, h = 270.0, sense = -1 },
                { id = 'gate.lane2.inner.lead_l', model = 'brdc_bifold_lead_l', x = 2419.09, y = 1378.205, z = 45.6242, h = 90.0, sense = 1 },
                { id = 'gate.lane2.inner.lead_r', model = 'brdc_bifold_lead_r', x = 2419.09, y = 1382.405, z = 45.6242, h = 90.0, sense = -1 },
            },
            follows = {
                { id = 'gate.lane2.outer.follow_l', model = 'brdc_bifold_follow_l', x = 2444.96, y = 1381.34, z = 45.6242, h = 270.0, lead = 1, ox = 1.065, oy = -0.04, oz = 0.0, turn = -2 },
                { id = 'gate.lane2.outer.follow_r', model = 'brdc_bifold_follow_r', x = 2444.96, y = 1379.27, z = 45.6242, h = 270.0, lead = 2, ox = -1.065, oy = -0.04, oz = 0.0, turn = -2 },
                { id = 'gate.lane2.inner.follow_l', model = 'brdc_bifold_follow_l', x = 2419.13, y = 1379.27, z = 45.6242, h = 90.0, lead = 3, ox = 1.065, oy = -0.04, oz = 0.0, turn = -2 },
                { id = 'gate.lane2.inner.follow_r', model = 'brdc_bifold_follow_r', x = 2419.13, y = 1381.34, z = 45.6242, h = 90.0, lead = 4, ox = -1.065, oy = -0.04, oz = 0.0, turn = -2 },
            },
            arm = { id = 'gate.lane2.outer_arm.arm', model = 'brdc_croparm_arm', x = 2447.0117, y = 1382.89, z = 45.452, h = 270.0, axis = 'y', sense = -1 },
        },
        {
            lane = 3,
            box = { x = 2432.643, y = 1387.01, ux = -1.0, uy = 0.0, halfLength = 14.6187, halfWidth = 2.095, zLow = 44.38, zHigh = 44.532 },
            leads = {
                { id = 'gate.lane3.outer.lead_l', model = 'brdc_bifold_lead_l', x = 2445.0, y = 1389.105, z = 45.6242, h = 270.0, sense = 1 },
                { id = 'gate.lane3.outer.lead_r', model = 'brdc_bifold_lead_r', x = 2445.0, y = 1384.915, z = 45.6242, h = 270.0, sense = -1 },
                { id = 'gate.lane3.inner.lead_l', model = 'brdc_bifold_lead_l', x = 2419.09, y = 1384.915, z = 45.6242, h = 90.0, sense = 1 },
                { id = 'gate.lane3.inner.lead_r', model = 'brdc_bifold_lead_r', x = 2419.09, y = 1389.105, z = 45.6242, h = 90.0, sense = -1 },
            },
            follows = {
                { id = 'gate.lane3.outer.follow_l', model = 'brdc_bifold_follow_l', x = 2444.96, y = 1388.04, z = 45.6242, h = 270.0, lead = 1, ox = 1.065, oy = -0.04, oz = 0.0, turn = -2 },
                { id = 'gate.lane3.outer.follow_r', model = 'brdc_bifold_follow_r', x = 2444.96, y = 1385.98, z = 45.6242, h = 270.0, lead = 2, ox = -1.065, oy = -0.04, oz = 0.0, turn = -2 },
                { id = 'gate.lane3.inner.follow_l', model = 'brdc_bifold_follow_l', x = 2419.13, y = 1385.98, z = 45.6242, h = 90.0, lead = 3, ox = 1.065, oy = -0.04, oz = 0.0, turn = -2 },
                { id = 'gate.lane3.inner.follow_r', model = 'brdc_bifold_follow_r', x = 2419.13, y = 1388.04, z = 45.6242, h = 90.0, lead = 4, ox = -1.065, oy = -0.04, oz = 0.0, turn = -2 },
            },
            arm = { id = 'gate.lane3.outer_arm.arm', model = 'brdc_croparm_arm', x = 2447.0117, y = 1389.59, z = 45.452, h = 270.0, axis = 'y', sense = -1 },
        },
    },
    readers = {
        { id = 'gate.lane1.reader_in', lane = 1, side = 'in', x = 2450.012, y = 1370.933, z = 45.712, h = 180.0 },
        { id = 'gate.lane1.reader_out', lane = 1, side = 'out', x = 2416.59, y = 1375.047, z = 45.712, h = 0.0 },
        { id = 'gate.lane2.reader_in', lane = 2, side = 'in', x = 2450.012, y = 1378.243, z = 45.712, h = 180.0 },
        { id = 'gate.lane2.reader_out', lane = 2, side = 'out', x = 2416.59, y = 1382.367, z = 45.712, h = 0.0 },
        { id = 'gate.lane3.reader_in', lane = 3, side = 'in', x = 2450.012, y = 1384.953, z = 45.712, h = 180.0 },
        { id = 'gate.lane3.reader_out', lane = 3, side = 'out', x = 2416.59, y = 1389.067, z = 45.712, h = 0.0 },
    },
}
