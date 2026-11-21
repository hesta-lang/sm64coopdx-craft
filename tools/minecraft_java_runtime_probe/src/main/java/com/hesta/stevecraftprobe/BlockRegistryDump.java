package com.hesta.stevecraftprobe;

import com.google.gson.Gson;
import com.google.gson.GsonBuilder;
import net.fabricmc.api.ModInitializer;
import net.fabricmc.fabric.api.event.lifecycle.v1.ServerLifecycleEvents;
import net.minecraft.core.BlockPos;
import net.minecraft.core.Direction;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.server.MinecraftServer;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.world.level.Level;
import net.minecraft.world.level.block.Block;
import net.minecraft.world.level.block.SoundType;
import net.minecraft.world.level.block.state.BlockState;
import net.minecraft.world.level.block.state.BlockBehaviour;
import net.minecraft.world.level.block.state.properties.Property;
import net.minecraft.world.phys.AABB;
import net.minecraft.world.phys.shapes.VoxelShape;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.lang.reflect.Field;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Collection;
import java.util.Comparator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.TreeMap;

public final class BlockRegistryDump implements ModInitializer {
    private static final Logger LOGGER = LoggerFactory.getLogger("SteveCraftBlockRuntimeProbe");
    private static final Gson GSON = new GsonBuilder().setPrettyPrinting().disableHtmlEscaping().create();
    private static final String FORMAT_VERSION = "1.0.0";
    private static final BlockPos SAMPLE_POS = new BlockPos(8, 80, 8);

    private static Field field(Class<?> type, String name) throws ReflectiveOperationException {
        Class<?> current = type;
        while (current != null) {
            try {
                Field result = current.getDeclaredField(name);
                result.setAccessible(true);
                return result;
            } catch (NoSuchFieldException ignored) {
                current = current.getSuperclass();
            }
        }
        throw new NoSuchFieldException(type.getName() + "." + name);
    }

    private static float floatField(Object instance, String name) throws ReflectiveOperationException {
        Object value = field(instance.getClass(), name).get(instance);
        if (!(value instanceof Number number)) throw new IllegalStateException("Field is not numeric: " + name);
        return number.floatValue();
    }

    private static boolean booleanField(Object instance, String name) throws ReflectiveOperationException {
        Object value = field(instance.getClass(), name).get(instance);
        if (!(value instanceof Boolean result)) throw new IllegalStateException("Field is not boolean: " + name);
        return result;
    }

    private static int intField(Object instance, String name) throws ReflectiveOperationException {
        Object value = field(instance.getClass(), name).get(instance);
        if (!(value instanceof Number number)) throw new IllegalStateException("Field is not numeric: " + name);
        return number.intValue();
    }

    private static String soundId(net.minecraft.sounds.SoundEvent soundEvent) {
        return soundEvent == null ? null : BuiltInRegistries.SOUND_EVENT.getKey(soundEvent).toString();
    }

    private static Map<String, Object> soundType(Block block) throws ReflectiveOperationException {
        SoundType sound = (SoundType) field(BlockBehaviour.class, "soundType").get(block);
        Map<String, Object> result = new LinkedHashMap<>();
        result.put("volume", sound.getVolume());
        result.put("pitch", sound.getPitch());
        result.put("break", soundId(sound.getBreakSound()));
        result.put("step", soundId(sound.getStepSound()));
        result.put("place", soundId(sound.getPlaceSound()));
        result.put("hit", soundId(sound.getHitSound()));
        result.put("fall", soundId(sound.getFallSound()));
        return result;
    }

    private static List<Map<String, Double>> shapeBoxes(VoxelShape shape) {
        List<Map<String, Double>> result = new ArrayList<>();
        for (AABB box : shape.toAabbs()) {
            Map<String, Double> item = new LinkedHashMap<>();
            item.put("min_x", box.minX);
            item.put("min_y", box.minY);
            item.put("min_z", box.minZ);
            item.put("max_x", box.maxX);
            item.put("max_y", box.maxY);
            item.put("max_z", box.maxZ);
            result.add(item);
        }
        return result;
    }

    @SuppressWarnings({"rawtypes", "unchecked"})
    private static Map<String, String> stateProperties(BlockState state) {
        Map<String, String> values = new TreeMap<>();
        for (Map.Entry<Property<?>, Comparable<?>> entry : state.getValues().entrySet()) {
            Property property = entry.getKey();
            values.put(property.getName(), property.getName(entry.getValue()));
        }
        return values;
    }

    private static Map<String, Object> extractState(
        BlockState state, ServerLevel level, BlockPos pos, BlockState defaultState
    ) {
        Map<String, Object> result = new LinkedHashMap<>();
        result.put("properties", stateProperties(state));
        result.put("is_default", state.equals(defaultState));

        Map<String, Object> runtime = new LinkedHashMap<>();
        try {
            runtime.put("destroy_speed", floatField(state, "destroySpeed"));
            runtime.put("light_emission", intField(state, "lightEmission"));
            runtime.put("light_dampening", intField(state, "lightDampening"));
        } catch (ReflectiveOperationException exception) {
            throw new IllegalStateException("Unable to read per-state runtime fields for " + state, exception);
        }

        runtime.put("fluid_id", BuiltInRegistries.FLUID.getKey(state.getFluidState().getType()).toString());
        runtime.put("fluid_empty", state.getFluidState().isEmpty());
        runtime.put("is_air", state.isAir());
        runtime.put("is_randomly_ticking", state.isRandomlyTicking());
        runtime.put("requires_correct_tool_for_drops", state.requiresCorrectToolForDrops());
        runtime.put("is_signal_source", state.isSignalSource());

        Map<String, Object> redstone = new LinkedHashMap<>();
        redstone.put("sampled_conductor", state.isRedstoneConductor(level, pos));
        redstone.put("sampled_signal_up", state.getSignal(level, pos, Direction.UP));
        redstone.put("sampled_analog_signal_up", state.hasAnalogOutputSignal()
            ? state.getAnalogOutputSignal(level, pos, Direction.UP) : 0);
        redstone.put("context", "empty_server_world_at_sample_position");
        runtime.put("redstone", redstone);

        runtime.put("collision_shape_boxes", shapeBoxes(state.getCollisionShape(level, pos)));
        runtime.put("outline_shape_boxes", shapeBoxes(state.getShape(level, pos)));
        runtime.put("occlusion_shape_boxes", shapeBoxes(state.getOcclusionShape()));
        runtime.put("shape_context", "empty_server_world_at_sample_position; neighbor-sensitive states are contextual samples");

        result.put("runtime", runtime);
        return result;
    }

    private static Map<String, Object> extractBlock(Block block, ServerLevel level, BlockPos pos)
        throws ReflectiveOperationException {
        String id = BuiltInRegistries.BLOCK.getKey(block).toString();
        BlockState defaultState = block.defaultBlockState();

        Map<String, Object> result = new LinkedHashMap<>();
        result.put("id", id);

        Map<String, Object> blockProperties = new LinkedHashMap<>();
        blockProperties.put("explosion_resistance", floatField(block, "explosionResistance"));
        blockProperties.put("friction", floatField(block, "friction"));
        blockProperties.put("speed_factor", floatField(block, "speedFactor"));
        blockProperties.put("jump_factor", floatField(block, "jumpFactor"));
        blockProperties.put("bounce_restitution", floatField(block, "bounceRestitution"));
        blockProperties.put("fall_distance_reduction", floatField(block, "fallDistanceReduction"));
        blockProperties.put("dynamic_shape", booleanField(block, "dynamicShape"));
        blockProperties.put("has_collision", booleanField(block, "hasCollision"));
        blockProperties.put("sounds", soundType(block));
        result.put("block_properties", blockProperties);

        Collection<BlockState> possibleStates = block.getStateDefinition().getPossibleStates();
        List<BlockState> orderedStates = new ArrayList<>(possibleStates);
        orderedStates.sort(Comparator.comparing(state -> stateProperties(state).toString()));

        List<Map<String, Object>> states = new ArrayList<>(orderedStates.size());
        for (BlockState state : orderedStates) {
            states.add(extractState(state, level, pos, defaultState));
        }
        result.put("states", states);
        return result;
    }

    private static Path outputPath() {
        String configured = System.getProperty("stevecraft.blockdata.output");
        if (configured == null || configured.isBlank()) configured = "stevecraft-block-runtime.json";
        return Path.of(configured).toAbsolutePath().normalize();
    }

    private static void dump(MinecraftServer server) {
        try {
            ServerLevel level = server.getLevel(Level.OVERWORLD);
            if (level == null) throw new IllegalStateException("Overworld was not available at SERVER_STARTED");
            level.getChunkAt(SAMPLE_POS);

            List<Map<String, Object>> blocks = new ArrayList<>();
            int totalStates = 0;
            for (Block block : BuiltInRegistries.BLOCK) {
                Map<String, Object> item = extractBlock(block, level, SAMPLE_POS);
                @SuppressWarnings("unchecked")
                List<Map<String, Object>> states = (List<Map<String, Object>>) item.get("states");
                totalStates += states.size();
                blocks.add(item);
            }
            blocks.sort(Comparator.comparing(item -> (String) item.get("id")));

            Map<String, Object> document = new LinkedHashMap<>();
            document.put("format_version", FORMAT_VERSION);
            document.put("minecraft_version", "26.3");
            document.put("source", Map.of(
                "kind", "fabric_server_runtime",
                "fabric_loader_version", "0.20.1",
                "runtime", "dedicated_server"
            ));
            document.put("coverage", Map.of(
                "block_registry_entries", blocks.size(),
                "block_state_entries", totalStates,
                "all_registry_blocks_seen", true,
                "collision_shape_context", "empty_server_world_at_sample_position",
                "collision_shapes_are_universal", false,
                "note", "Shapes and redstone readings are contextual samples; blocks with neighbor-, entity-, fluid-, or block-entity-dependent behavior require additional world-state scenarios."
            ));
            document.put("blocks", blocks);

            Path output = outputPath();
            Files.createDirectories(output.getParent());
            Files.writeString(output, GSON.toJson(document));
            LOGGER.info("SteveCraft runtime registry dump complete: {} blocks, {} states -> {}", blocks.size(), totalStates, output);
            server.halt(false);
        } catch (Throwable throwable) {
            LOGGER.error("SteveCraft runtime registry dump failed", throwable);
            server.halt(false);
            throw new RuntimeException("Runtime registry extraction failed", throwable);
        }
    }

    @Override
    public void onInitialize() {
        ServerLifecycleEvents.SERVER_STARTED.register(BlockRegistryDump::dump);
        LOGGER.info("SteveCraft Minecraft 26.3 block runtime probe registered.");
    }
}
