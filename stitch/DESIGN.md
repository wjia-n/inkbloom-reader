# InkBloom Reader — Stitch reference
_Stitch is the visual source of truth. Flutter implements layout, interaction, animation and logic using these Stitch-created visuals._
- Project: InkBloom Reader — `projects/9125903592131139162`
- Design system: "Warm Paper Editorial" — independent bookshop / reading nook, typography-driven, high-legibility, zero cognitive friction. Warm paper surfaces, deep ink typography, terracotta accents, soft warm shadows, 48px+ touch targets.
- Library screen: `a2104c4491924f36944e43a915394d35` — "InkBloom Reader - Library"
  - Add a Book banner on top (one tap), Currently Reading hero with Resume button + progress, Quick tools (Dictionary, Daily Goal, Move to New Phone), shelves + book grid, bottom navigation.
  - Applied in Flutter library: Add Book banner, Currently Reading hero, Dictionary / Move to new phone / Language tool cards.
- Reader + Settings screens: generated from the same idea prompt in this project (see reader.json / settings.json).
- Reader screen: `e84691e497f84f00a211c5098c0da3c0` — "InkBloom Reader - Active Reading View"
  - Calm paper, serif, drop cap, inline dictionary card, floating dock with chapter progress + time left, Day/Sepia/Night switch, Listen, bookmark. Most already in the Flutter reader; drop cap + time-left-in-chapter are future, not in v1.0.1.
- Settings screen: `ef7f039b4ebd490992d4766782e0c50c` — "InkBloom Reader - Settings & Phone Transfer"
  - Prominent terracotta Migrate card, paper tone swatches, font selector + size slider, dictionary controls, goal stepper, private local storage meter. Flutter transfer in v1.0.1 is a file backup (.inkbloom zip), NOT a QR code — Stitch's QR idea is future, do not claim it.
