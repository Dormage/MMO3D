# Extra mobs: 53 rigged models from the rest of poly.pizza

These are the animated models outside the monster and enemy packs that still carry a hit
reaction, a death clip and a run clip. Every one was found by the sitewide sweep described
in the parent README.

## Layout

Each folder holds the original FBX, the GLB conversion and a model.json with clip names:

```
mobs_extra/
  manifest.json      clip names, tri count, bone count, licence, source page
  animations.csv     hit, death and run clip name per model
  <Name>_<id>/
    <Name>_<id>.fbx
    <Name>_<id>.glb
    model.json
```

## What is in here

7 are enemy or creature rigs: four mechs, a giant, a shark character and a
third zombie from another creator. 38 are humanoid NPC rigs (workers, astronauts, adventurers,
soldiers, punks, a king, witches). 8 are animals (panda, rabbits, dogs).

The bucket in each model.json comes from the model title, so treat it as a rough label.
Rigs sharing the same skeleton (the 24 clip character set) let you swap models on one
animation set.

## Licence

44 are CC0 1.0, 9 are CC-BY 3.0 and need credit.
Every model records its licence and creator in model.json.
