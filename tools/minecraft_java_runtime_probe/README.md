# SteveCraft Minecraft Java 26.3 runtime registry probe

This is a temporary Fabric server-only research mod. It is not included in the
SM64CoopDX player mod and does not modify an APK.

The probe iterates the live Java block registry and every registered state. It
reads state-level destroy speed, light emission/dampening, fluid identity,
random tick and tool-drop flags; block-level explosion resistance, friction,
movement factors, bounce/fall behavior, dynamic-shape and collision flags; and
the five block sound event IDs. It also serializes collision, outline, and
occlusion VoxelShape boxes, plus redstone outputs.

The probe uses Minecraft Java 26.3, Fabric Loader 0.20.1, Fabric API 0.166.2,
Fabric Loom 1.19-SNAPSHOT and Java 25, matching the Fabric 26.3 example project.

## Context limitations

Collision, outline and redstone behavior may depend on neighboring blocks,
entities, fluids, block entities, or the queried world. This first pass samples
all possible block states in an otherwise empty dedicated-server world at one
loaded position. The output records that context and explicitly sets
collision_shapes_are_universal=false. It must not be interpreted as a complete
world-context collision catalogue.

Block hardness is state-specific (destroy_speed), while explosion resistance,
friction, speed factor, jump factor, bounce restitution and fall-distance
reduction are read from the Java BlockBehaviour instance. The probe uses
reflection against exact 26.3 runtime field names; CI treats a field rename or
missing field as a failure rather than silently filling a guessed value.

Run through the SteveCraft Research Pipeline workflow. The dedicated server
writes JSON to the path supplied by the system property
stevecraft.blockdata.output and halts after a successful dump.
