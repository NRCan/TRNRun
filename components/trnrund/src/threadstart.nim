## Starts threads under the strict initialization checks `config.nims` enables.

template startThread*(thread, body, arg: untyped) =
  ## `createThread`, silencing the warnings `strictDefs` raises on the `thread` it initializes.
  {.push warning[ProveInit]: off, warning[Uninit]: off.}
  createThread(thread, body, arg)
  {.pop.}
