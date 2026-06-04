/// The fixed sequence of photos a volunteer captures for one hearing aid.
///
/// The slot's [name] becomes its Storage filename
/// (`scans/{uid}/incoming/{id}/{name}.jpg`), so the *identity* of the photo —
/// which face was shot — is encoded by the filename, not by list position.
/// (An earlier position-based scheme silently mislabelled photos whenever a
/// slot was skipped and the upload list compacted.)
///
/// The face vocabulary (medial/lateral/anterior/posterior/superior/inferior)
/// is the audiology-aligned anatomical taxonomy used across the project, so
/// audiologists reading the register later recognise it natively.
enum CaptureSlot {
  scale(
    title: 'Scale',
    hint: 'Lay the device next to a credit card for size reference.',
  ),
  medial(
    title: 'Brand label',
    hint: 'Inner face — show the printed brand/model (text runs sideways).',
  ),
  lateral(
    title: 'Outer side',
    hint: 'The large outer face, the side that points away from the head.',
  ),
  anterior(
    title: 'Front edge',
    hint: 'The thin front edge (the side toward the face).',
  ),
  posterior(
    title: 'Back edge',
    hint: 'The thin back edge (the side away from the face).',
  ),
  superior(
    title: 'Top / hook',
    hint: 'The top, where the hook or tubing attaches.',
  ),
  inferior(
    title: 'Bottom',
    hint: 'The underside of the device.',
  );

  const CaptureSlot({required this.title, required this.hint});

  /// Short label shown above the capture button.
  final String title;

  /// One-line guidance for what to frame.
  final String hint;

  /// The full ordered sequence the capture flow steps through.
  static const List<CaptureSlot> sequence = values;
}
