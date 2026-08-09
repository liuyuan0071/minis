package com.openminis.app.data.db

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query
import kotlinx.coroutines.flow.Flow

@Dao
interface SubAgentDao {
    @Query("SELECT * FROM sub_agents ORDER BY updated_at DESC")
    fun observeAll(): Flow<List<SubAgentEntity>>

    @Query("SELECT * FROM sub_agents ORDER BY updated_at DESC")
    suspend fun listAll(): List<SubAgentEntity>

    @Query("SELECT * FROM sub_agents WHERE id = :id")
    suspend fun getById(id: String): SubAgentEntity?

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsert(agent: SubAgentEntity)

    @Query("UPDATE sub_agents SET name = :name, description = :description, model_id = :modelId, skills_json = :skillsJson, builtin_tools_json = :builtinToolsJson, body = :body, source = :source, is_enabled = :isEnabled, updated_at = :updatedAt WHERE id = :id")
    suspend fun update(
        id: String,
        name: String,
        description: String,
        modelId: String?,
        skillsJson: String,
        builtinToolsJson: String,
        body: String,
        source: String,
        isEnabled: Boolean,
        updatedAt: Long,
    )

    @Query("UPDATE sub_agents SET is_enabled = :isEnabled, updated_at = :updatedAt WHERE id = :id")
    suspend fun setEnabled(id: String, isEnabled: Boolean, updatedAt: Long)

    @Query("DELETE FROM sub_agents WHERE id = :id")
    suspend fun deleteById(id: String)

    @Query("SELECT COUNT(*) FROM sub_agents")
    suspend fun count(): Int
}
