# Recorder presence

In record-only mode, starting either a manual or automatically detected capture writes a small JSON presence document under `intake/recorder-presence` beside the selected output root’s `recordings` directory. Sync this directory along with recordings to the meeting tracker.

The document uses the `shalashaska.recorder-presence` version 1 contract, with an opaque session ID, eventual audio filename, status, and zoned start/update timestamps. It contains no audio, participants, or meeting title. A recording heartbeat is written every 30 seconds, using atomic replacement. A successful stop publishes `stopped`; cancellation or failed finalization removes the active document. Publication errors do not interrupt capture.

The output destination is captured at recording start, so changing settings during a capture cannot send its signal and finalized audio to different roots. Signals become visible after folder synchronization and the tracker refresh. A crashed or offline recorder cannot continue heartbeats; the tracker marks those signals lost rather than assuming capture continues.

The source baseline in this fork matches upstream commit `ce997f5b6aa2957582f4c6a720eb239dd04f9eba`. The presence change is a separate commit to make its capture integration reviewable. Formatting uses SwiftFormat 0.60.1, matching that baseline’s style.
