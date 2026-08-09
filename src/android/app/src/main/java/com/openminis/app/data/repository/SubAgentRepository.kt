package com.openminis.app.data.repository

import android.content.Context
import android.util.Log
import com.openminis.app.data.db.AppDatabase
import com.openminis.app.data.db.SubAgentDao
import com.openminis.app.data.db.SubAgentEntity
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import org.json.JSONArray
import java.io.File

/**
 * Manages sub-agent definitions (Claude Code `.claude/agents` markdown shape).
 *
 * Architecture mirrors SkillRepository:
 *   - The markdown file is the single source of truth on disk at
 *     `filesDir/minis-global/agents/<name>.md`
 *   - Room (`sub_agents` table) caches the parsed metadata for fast listing
 *     and prompt assembly
 *   - The YAML frontmatter carries `name` / `description` / `tools` /
 *     `model`; the markdown body IS the sub-agent's system prompt
 *
 * A sub-agent is STATELESS when invoked (fresh context each call) but its
 * chat sessions are persistent — session↔agent binding lives on the sessions
 * table via `sub_agent_id`.
 */
class SubAgentRepository(private val context: Context) {

    companion object {
        private const val TAG = "SubAgentRepository"
        const val SOURCE_IMPORTED = "imported"
        const val SOURCE_GENERATED = "generated"
        const val SOURCE_BUILTIN = "builtin"
    }

    private val dao: SubAgentDao = AppDatabase.getInstance(context).subAgentDao()

    /** `filesDir/minis-global/agents/` — mirror of SkillRepository's skills dir. */
    private val agentsDir: File
        get() = File(context.filesDir, "minis-global/agents")

    // [T-subagent-builtin-list] In-memory cache of the agent table so
    // synchronous prompt assembly (buildSystemPrompt is not a suspend fn)
    // can disclose available sub-agents without a blocking Room call.
    // Kept in sync by collecting the DAO flow; also seeds bundled agents.
    private val _agents = MutableStateFlow<List<SubAgentEntity>>(emptyList())
    val agents: StateFlow<List<SubAgentEntity>> = _agents.asStateFlow()

    init {
        CoroutineScope(Dispatchers.IO).launch {
            runCatching {
                dao.observeAll().collect { _agents.value = it }
            }.onFailure { Log.w(TAG, "observeAll collect failed: ${it.message}") }
        }
        // Install the pre-packaged 数字员工 agents from
        // assets/bundled-agents/ (idempotent — existing ids are skipped so
        // a user who deleted one won't get it re-installed on next launch).
        CoroutineScope(Dispatchers.IO).launch {
            installBundledAgents()
        }
    }

    // -- Listing --

    fun observeAll(): Flow<List<SubAgentEntity>> = dao.observeAll()

    suspend fun listAll(): List<SubAgentEntity> = dao.listAll()

    suspend fun getById(id: String): SubAgentEntity? = dao.getById(id)

    // -- CRUD --

    /**
     * Import a sub-agent from raw markdown content (YAML frontmatter + body).
     * Returns the entity, or null when the content has no valid frontmatter
     * / blank name.
     */
    suspend fun importFromContent(
        content: String,
        source: String = SOURCE_IMPORTED,
    ): SubAgentEntity? {
        val parsed = parseAgentMd(content) ?: return null
        val id = slugify(parsed.name)
        if (id.isBlank()) return null

        val existing = dao.getById(id)
        val entity = SubAgentEntity(
            id = id,
            name = parsed.name,
            description = parsed.description,
            modelId = parsed.modelId,
            skillsJson = JSONArray(parsed.skills).toString(),
            builtinToolsJson = JSONArray(parsed.builtinTools).toString(),
            body = parsed.body,
            source = source,
            isEnabled = existing?.isEnabled ?: true,
            createdAt = existing?.createdAt ?: System.currentTimeMillis(),
            updatedAt = System.currentTimeMillis(),
        )
        dao.upsert(entity)
        writeAgentMd(entity)
        Log.i(TAG, "Imported sub-agent: ${entity.id}")
        return entity
    }

    /** Update metadata (skills subset / model override / enabled). */
    suspend fun updateMeta(
        id: String,
        name: String? = null,
        description: String? = null,
        modelId: String? = null,
        skills: List<String>? = null,
        builtinTools: List<String>? = null,
        body: String? = null,
        isEnabled: Boolean? = null,
    ): SubAgentEntity? {
        val current = dao.getById(id) ?: return null
        val updated = current.copy(
            name = name ?: current.name,
            description = description ?: current.description,
            modelId = if (modelId !== null) modelId else current.modelId,
            skillsJson = if (skills != null) JSONArray(skills).toString() else current.skillsJson,
            builtinToolsJson = if (builtinTools != null) JSONArray(builtinTools).toString() else current.builtinToolsJson,
            body = body ?: current.body,
            isEnabled = isEnabled ?: current.isEnabled,
            updatedAt = System.currentTimeMillis(),
        )
        dao.upsert(updated)
        writeAgentMd(updated)
        return updated
    }

    suspend fun setEnabled(id: String, enabled: Boolean) {
        dao.setEnabled(id, enabled, System.currentTimeMillis())
        // Keep the on-disk md in sync so a reloadFromDisk scan sees it.
        runCatching {
            val entity = dao.getById(id) ?: return
            writeAgentMd(entity)
        }
    }

    suspend fun delete(id: String) {
        dao.deleteById(id)
        File(agentsDir, "$id.md").delete()
        Log.i(TAG, "Deleted sub-agent: $id")
    }

    // -- Prompt fragment (session bound to a sub-agent) --

    /**
     * Build the system-prompt fragment that makes a bound sub-agent's
     * identity + instructions available to the agent loop. Returns null when
     * the agent is missing/disabled or [agentId] is null (ordinary session).
     *
     * Skill restriction is intentionally NOT embedded here — the agent loop
     * filters the global skill list via [allowedSkillIds] instead, so the
     * `available_skills` XML stays the single source of truth for skill
     * discovery (matching how the base prompt consumes SkillRepository's
     * fragment).
     */
    suspend fun agentPromptFragment(agentId: String?): String? {
        if (agentId == null) return null
        val agent = dao.getById(agentId) ?: return null
        if (!agent.isEnabled) return null
        return buildString {
            append("You are acting as the sub-agent \"")
            append(agent.name)
            append("\". ")
            if (agent.description.isNotBlank()) {
                append(agent.description)
                append(" ")
            }
            append("Follow its instructions below strictly — they override the generic assistant guidance.\n\n")
            append(agent.body)
        }
    }

    /**
     * Disclose the available sub-agents to an ordinary (non-bound) session
     * so the model can summon them via subagent_invoke by id, and know how
     * to CREATE a new one (write an agent .md under /var/minis/agents/).
     * Synchronous: reads the cached [agents] flow, not the DAO.
     */
    fun availableSubAgentsFragment(): String? {
        val list = _agents.value.filter { it.isEnabled }
        if (list.isEmpty()) return null
        return buildString {
            appendLine("Available sub-agents (summon via the subagent_invoke tool; the value of `agent` is the id below):")
            list.forEach { a ->
                append("- id=${a.id}")
                if (a.description.isNotBlank()) append(", ${a.name}: ${a.description}")
                else append(", ${a.name}")
                appendLine()
            }
            appendLine(
                "You can also CREATE a new sub-agent yourself: write an agent definition .md to " +
                    "/var/minis/agents/<id>.md with YAML frontmatter (`name`, `description`, " +
                    "optional `model` and `tools` as a skill-id list) followed by the markdown body " +
                    "that IS the sub-agent's system prompt. The file name should match the agent name " +
                    "(Chinese names are fine). It registers automatically within a turn."
            )
        }
    }

    /** Parsed skill ids a sub-agent may use (empty = all / inherit). */
    suspend fun allowedSkillIds(agentId: String?): List<String> {
        if (agentId == null) return emptyList()
        val agent = dao.getById(agentId) ?: return emptyList()
        if (agent.skillsJson.isBlank() || agent.skillsJson == "[]") return emptyList()
        return runCatching {
            val arr = JSONArray(agent.skillsJson)
            List(arr.length()) { arr.getString(it) }
        }.getOrDefault(emptyList())
    }

    /** Parsed builtin tool names a sub-agent may use (empty = all tools). */
    suspend fun allowedBuiltinTools(agentId: String?): List<String> {
        if (agentId == null) return emptyList()
        val agent = dao.getById(agentId) ?: return emptyList()
        if (agent.builtinToolsJson.isBlank() || agent.builtinToolsJson == "[]") return emptyList()
        return runCatching {
            val arr = JSONArray(agent.builtinToolsJson)
            List(arr.length()) { arr.getString(it) }
        }.getOrDefault(emptyList())
    }

    /** Optional model override (null = inherit session model). */
    suspend fun modelOverride(agentId: String?): String? {
        if (agentId == null) return null
        return dao.getById(agentId)?.modelId?.takeIf { it.isNotBlank() }
    }

    /**
     * Re-scan the agents dir on disk and promote any .md files not yet in
     * Room (e.g. agent file_write of a new agent md, or an out-of-band copy).
     * Mirrors SkillRepository.reloadFromDisk().
     */
    suspend fun reloadFromDisk() {
        val known = dao.listAll().map { it.id }.toSet()
        val dir = agentsDir
        if (!dir.exists()) return
        for (file in dir.listFiles()?.filter { it.isFile && it.name.endsWith(".md") } ?: emptyList()) {
            val id = file.name.removeSuffix(".md")
            if (id in known) continue
            val parsed = parseAgentMd(file.readText()) ?: continue
            if (slugify(parsed.name) != id) continue
            dao.upsert(
                SubAgentEntity(
                    id = id,
                    name = parsed.name,
                    description = parsed.description,
                    modelId = parsed.modelId,
                    skillsJson = JSONArray(parsed.skills).toString(),
                    builtinToolsJson = JSONArray(parsed.builtinTools).toString(),
                    body = parsed.body,
                    source = SOURCE_GENERATED,
                )
            )
            Log.i(TAG, "Auto-discovered sub-agent: $id")
        }
    }

    // -- Parsing --

    data class ParsedAgent(
        val name: String,
        val description: String,
        val modelId: String?,
        val skills: List<String>,
        val builtinTools: List<String>,
        val body: String,
    )

    /**
     * Parse a Claude Code agent md: YAML frontmatter (`name`, `description`,
     * `tools` (skill ids), `model`) + markdown body.
     */
    private fun parseAgentMd(content: String): ParsedAgent? {
        val trimmed = content.trimStart()
        if (!trimmed.startsWith("---")) return null
        val lines = trimmed.lines()
        var frontmatterEnd = -1
        for (i in 1 until lines.size) {
            if (lines[i].trim() == "---") { frontmatterEnd = i; break }
        }
        if (frontmatterEnd < 0) return null

        var name = ""
        var description = ""
        var modelId: String? = null
        val skills = mutableListOf<String>()
        val builtinTools = mutableListOf<String>()

        var i = 1
        while (i < frontmatterEnd) {
            val line = lines[i]
            val colonIdx = line.indexOf(':')
            if (colonIdx < 0) { i++; continue }
            val key = line.substring(0, colonIdx).trim().lowercase()
            val rawValue = line.substring(colonIdx + 1).trim()

            when (key) {
                "name" -> name = rawValue
                "description" -> description = rawValue
                "model" -> modelId = rawValue
                "tools" -> {
                    // YAML list: `tools:\n  - skill-a\n  - skill-b` OR comma list
                    if (rawValue.isEmpty() || rawValue == "[" || rawValue == "[]") {
                        var j = i + 1
                        while (j < frontmatterEnd) {
                            val next = lines[j].trim()
                            if (next.startsWith("- ")) {
                                skills.add(next.removePrefix("- ").trim())
                            } else if (next.startsWith("[") || next.startsWith("]")) {
                                // ignore bracket-only lines
                            } else break
                            j++
                        }
                        i = j
                    } else {
                        // inline: tools: a, b, c
                        rawValue.trim('[', ']').split(',')
                            .map { it.trim() }
                            .filter { it.isNotEmpty() }
                            .forEach { skills.add(it) }
                        i++
                    }
                }
            }
            i++
        }

        if (name.isBlank()) return null

        val bodyStart = frontmatterEnd + 1
        val body = if (bodyStart < lines.size) {
            lines.subList(bodyStart, lines.size).joinToString("\n").trim('\n')
        } else ""

        return ParsedAgent(name, description, modelId, skills, builtinTools, body)
    }

    // -- Disk --

    private fun writeAgentMd(agent: SubAgentEntity) {
        agentsDir.mkdirs()
        val content = buildString {
            appendLine("---")
            appendLine("name: ${agent.name}")
            if (agent.description.isNotBlank()) appendLine("description: ${agent.description}")
            agent.modelId?.let { appendLine("model: $it") }
            if (agent.skillsJson != "[]") {
                appendLine("tools:")
                val arr = JSONArray(agent.skillsJson)
                for (j in 0 until arr.length()) {
                    appendLine("  - ${arr.getString(j)}")
                }
            }
            appendLine("---")
            append(agent.body)
        }
        File(agentsDir, "${agent.id}.md").writeText(content)
    }

    // -- Builtin agents --

    /**
     * Install the pre-packaged 数字员工 agents shipped under
     * `assets/bundled-agents/*.md` (Claude Code agent shape, same as
     * [importFromContent]). Idempotent: an id that already exists is
     * skipped, so a user can delete/disable a bundled agent and it won't
     * be re-installed on the next launch. Mirrors
     * SkillRepository.installBundledSkillPacks().
     */
    private suspend fun installBundledAgents() {
        try {
            val files = context.assets.list("bundled-agents") ?: return
            for (fileName in files.sorted()) {
                if (!fileName.endsWith(".md")) continue
                val id = fileName.removeSuffix(".md")
                if (dao.getById(id) != null) continue   // already installed
                try {
                    val content = context.assets.open("bundled-agents/$fileName")
                        .bufferedReader(Charsets.UTF_8).use { it.readText() }
                    val entity = importFromContent(content, source = SOURCE_BUILTIN)
                    if (entity != null) {
                        Log.i(TAG, "Installed bundled sub-agent: ${entity.id}")
                    } else {
                        Log.w(TAG, "Bundled sub-agent parse failed: $fileName")
                    }
                } catch (e: Exception) {
                    Log.w(TAG, "Failed to install bundled sub-agent: $fileName - ${e.message}")
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "Failed to list bundled-agents assets: ${e.message}")
        }
    }

    private fun slugify(name: String): String =
        name.lowercase()
            // [T-subagent-cn-name] Keep Unicode letters (CJK etc.) so a pure
            // Chinese agent name like "数据分析师" yields a usable id instead
            // of an empty string that made importFromContent fail.
            .replace(Regex("[^a-z0-9\\p{L}]+"), "-")
            .trim('-')
}
