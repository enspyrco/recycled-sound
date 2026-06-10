/// The fixed sequence of photos a volunteer captures for one hearing aid.
///
/// The slot's [name] becomes its Storage filename
/// (`captures/{uid}/{deviceId}/{slot}.jpg`), so the *identity* of the photo —
/// which face was shot — is encoded by the filename, not by list position.
/// (An earlier position-based scheme silently mislabelled photos whenever a
/// slot was skipped and the upload list compacted.)
///
/// The face vocabulary (medial/lateral/anterior/posterior/superior/inferior)
/// is the audiology-aligned anatomical taxonomy used across the project, so
/// audiologists reading the register later recognise it natively.
///
/// Each slot carries a [why] sentence as well as the [hint]: the volunteer is a
/// non-expert, so the guidance leads with the plain-language *what to shoot*,
/// then says *why this photo matters* so it never reads as an arbitrary step.
/// (Recognition over recall — the screen tells you what good looks like rather
/// than assuming you remember the protocol.)
enum CaptureSlot {
  scale(
    title: 'Size shot',
    hint: 'Lay the hearing aid flat next to a credit card and shoot both.',
    why: 'The card is a known size, so this photo lets us measure the device.',
  ),
  medial(
    title: 'Brand label',
    hint: 'Photograph the inner face where the brand and model are printed '
        '(the tiny text usually runs sideways).',
    why: 'This is the photo that tells us which hearing aid it is.',
  ),
  lateral(
    title: 'Outer face',
    hint: 'The big flat outer side — the part that faces away from the head '
        'when the aid is worn.',
    why: 'Shows the overall shape, colour, and any buttons.',
  ),
  anterior(
    title: 'Front edge',
    hint: 'Turn the aid so the thin front edge (the side toward the face) '
        'points at the camera.',
    why: 'Edge views help an audiologist read the style and controls.',
  ),
  posterior(
    title: 'Back edge',
    hint: 'Turn the aid so the thin back edge (the side away from the face) '
        'points at the camera.',
    why: 'The opposite edge view, for the same reason.',
  ),
  superior(
    title: 'Top / hook',
    hint: 'Look down on the top, where the hook or tubing attaches.',
    why: 'Shows the tubing and how the aid connects to the ear.',
  ),
  inferior(
    title: 'Underside',
    hint: 'Flip it over and shoot the bottom, including the battery door.',
    why: 'The battery door tells us the battery size or if it recharges.',
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

  /// The full ordered sequence the capture flow steps through.
  static const List<CaptureSlot> sequence = values;
}
