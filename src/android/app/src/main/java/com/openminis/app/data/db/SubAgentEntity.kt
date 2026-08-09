package com.openminis.app.data.db

import androidx.room.ColumnInfo
import androidx.room.Entity
import androidx.room.PrimaryKey

/**
 * A sub-agent definition (Claude Code `.claude/agents` markdown shape).
 *
 * The markdown body (YAML frontmatter + instructions) is stored on disk at
 * `filesDir/minis-global/agents/<name>.md` (single source of truth, mirroring
 * how SkillRepository stores SKILL.md). This Room row caches the parsed
 * metadata for listing and prompt assembly without re-parsing every file.
 *
 * `source` mirrors SkillRepository.ImportSource values ("imported" /
 * "generated" / "builtin") so the UI can group and label entries.
 */
@Entity(tableName = "sub_agents")
data class SubAgentEntity(
    @PrimaryKey val id: String,
    val name: String,
    val description: String = "",
    /** Optional model override. null = inherit the session's model. */
    @ColumnInfo(name = "model_id") val modelId: String? = null,
    /** JSON array of skill ids this agent may use (subset of global skills). */
    @ColumnInfo(name = "skills_json") val skillsJson: String = "[]",
    /** JSON array of builtin tool names this agent may use. */
    @ColumnInfo(name = "builtin_tools_json") val builtinToolsJson: String = "[]",
    /** Markdown instruction body (after YAML frontmatter). */
    val body: String = "",
    /** "imported" | "generated" | "builtin" */
    val source: String = "imported",
    @ColumnInfo(name = "is_enabled") val isEnabled: Boolean = true,
    @ColumnInfo(name = "created_at") val createdAt: Long = System.currentTimeMillis(),
    @ColumnInfo(name = "updated_at") val updatedAt: Long = System.currentTimeMillis(),
)
