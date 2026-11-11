# Step-1 section-1 settling test PR (scratch only)

Synthetic PR for the max_checks_retries section-1 experiment (2026-11-11).
Its only purpose is to enter the Mergify queue with a passing merge
condition (`shadow-ci`) while a non-merge-condition check (`shadow-flaky`)
fails, and observe whether Mergify merges or dequeues it.

DO NOT apply to gigafab. This repo is jajabong/gigafab-mq-scratch.
