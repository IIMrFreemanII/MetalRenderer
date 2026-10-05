---
name: feedback-ping-training
description: "Send the user a push notification when a long training run (or other long job they wait on) starts"
metadata:
  type: feedback
---

When the neural denoiser's training starts, ping the user (push notification), not just a line in the transcript.

**Why:** the user asked "ping me when training starts" on 2026-10-05; the dataset takes hours and they work on other
things meanwhile.
**How to apply:** use the PushNotification tool when the first training run starts (and when a long job they are
waiting for finishes or fails). See [[neural-denoiser-status-2026-10]].
