## Starts threads under the strict initialization checks `config.nims` enables.

template startThread*(thread, body, arg: untyped) =
  ## `createThread(thread, body, arg)`. `createThread` initializes `thread`
  ## itself, which `strictDefs` cannot prove, so its warnings are silenced here.
  {.push warning[ProveInit]: off, warning[Uninit]: off.}
  createThread(thread, body, arg)
  {.pop.}
