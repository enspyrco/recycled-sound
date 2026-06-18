/// Which aid of the pair is being photographed.
///
/// Donations are ALWAYS a pair (left + right), so the capture flow runs the
/// full [CaptureSlot.sequence] once per side — 7 shots each, 14 in total. The
/// side is part of each photo's Storage filename (`{side}_{slot}.jpg`) so left
/// and right shots of the same orientation never collide.
enum AidSide {
  left('Left'),
  right('Right');

  const AidSide(this.label);

  /// Volunteer-facing label ("Left" / "Right").
  final String label;
}

/// One step of the capture flow: photograph [slot] orientation of the [side]
/// aid. The flow steps through [pairSequence] (14 steps) in order.
typedef CaptureStep = ({AidSide side, CaptureSlot slot});

/// The fixed set of photos a volunteer captures for ONE aid.
///
/// The slot's [name] (combined with the aid side) becomes its Storage filename
/// (`captures/{uid}/{deviceId}/{side}_{slot}.jpg`), so the *identity* of the
/// photo — which side, which orientation — is encoded by the filename, not by
/// list position. (An earlier position-based scheme silently mislabelled photos
/// whenever a slot was skipped and the upload list compacted.)
///
/// The names (medial/lateral/anterior/posterior/superior/inferior) are the
/// audiology-aligned anatomical taxonomy used across the project, so
/// audiologists reading the register later recognise it natively. The
/// volunteer never sees those words — they see [title]/[hint]/[why] in plain
/// language.
///
/// Vocabulary is deliberately consistent: a broad flat surface is a **side**, a
/// thin rim is an **edge**, and the two ends are **top** / **underside**. The
/// earlier copy mixed "face" and "side" and pinned the brand label to one face,
/// which confused volunteers (the label can be on either broad side).
enum CaptureSlot {
  scale(
    title: 'Size',
    hint: 'Lay the aid flat next to a credit card and fit both in the shot.',
    why: 'The card is a known size, so we can measure the aid from the photo.',
  ),
  medial(
    title: 'Brand & model',
    hint: 'Point the side with the brand and model printed on it at the '
        'camera — usually the inner side, but check both.',
    why: 'This is what tells us which hearing aid it is.',
  ),
  lateral(
    title: 'Outer side',
    hint: 'The big curved side that faces away from the head when the aid is '
        'worn.',
    why: 'Shows the overall shape, colour, and any buttons.',
  ),
  anterior(
    title: 'Front edge',
    hint: 'Stand the aid so its thin front edge points at the camera.',
    why: 'Edge views help an audiologist read the style and controls.',
  ),
  posterior(
    title: 'Back edge',
    hint: 'Turn the aid around so the opposite thin edge points at the camera.',
    why: 'The other edge, for the same reason.',
  ),
  superior(
    title: 'Top',
    hint: 'Look straight down on the top, where the hook or tube comes out.',
    why: 'Shows the hook and how the aid connects to the ear.',
  ),
  inferior(
    title: 'Underside',
    hint: 'Flip it over and shoot the bottom, where the battery door is.',
    why: 'The battery door shows the battery size or whether it recharges.',
  );

  const CaptureSlot({
    required this.title,
    required this.hint,
    required this.why,
  });

  /// Short label shown above the capture button.
  final String title;

  /// One-line guidance for *what to frame*.
  final String hint;

  /// One-line *why this photo matters*, shown under the hint. Keeps the step
  /// from reading as arbitrary to a non-expert volunteer.
  final String why;

  /// The ordered orientations captured for a single aid.
  static const List<CaptureSlot> sequence = values;

  /// The full 14-step flow: every orientation of the LEFT aid, then every
  /// orientation of the RIGHT aid. The order keeps a volunteer on one physical
  /// aid at a time rather than flipping back and forth between the pair.
  /// `final` not `const`: a record-typed `for`-element list can't be const.
  static final List<CaptureStep> pairSequence = [
    for (final side in AidSide.values)
      for (final slot in values) (side: side, slot: slot),
  ];
}
