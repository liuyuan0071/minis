package com.openminis.app.ui.subagents

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.ArrowBack
import androidx.compose.material.icons.filled.SmartToy
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.openminis.app.data.db.SubAgentEntity
import com.openminis.app.data.repository.SubAgentRepository
import kotlinx.coroutines.launch

/**
 * Sub-Agent management screen (stage-2). Lists registered agents, allows
 * import from markdown content, toggling enable state, deleting, and opening
 * a persistent chat session bound to the agent.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SubAgentsScreen(
    subAgentRepository: SubAgentRepository,
    chatRepository: com.openminis.app.data.repository.ChatRepository,
    defaultModelId: String,
    onBack: () -> Unit,
    onOpenSession: (sessionId: String) -> Unit,
) {
    val scope = rememberCoroutineScope()
    val snackbarHostState = remember { SnackbarHostState() }
    var agents by remember { mutableStateOf<List<SubAgentEntity>>(emptyList()) }
    var loading by remember { mutableStateOf(true) }
    var showImportDialog by remember { mutableStateOf(false) }
    var snackbar by remember { mutableStateOf<String?>(null) }

    LaunchedEffect(Unit) {
        agents = subAgentRepository.listAll()
        loading = false
    }

    LaunchedEffect(snackbar) {
        snackbar?.let { msg ->
            snackbarHostState.showSnackbar(msg)
            snackbar = null
        }
    }

    Scaffold(
        snackbarHost = { androidx.compose.material3.SnackbarHost(snackbarHostState) },
        topBar = {
            TopAppBar(
                title = { Text("子代理") },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.Filled.ArrowBack, contentDescription = "Back")
                    }
                },
                actions = {
                    IconButton(onClick = { showImportDialog = true }) {
                        Icon(Icons.Filled.Add, contentDescription = "导入")
                    }
                },
            )
        },
    ) { innerPadding ->
        Box(Modifier.padding(innerPadding).fillMaxSize()) {
            when {
                loading -> CircularProgressIndicator(Modifier.align(Alignment.Center))
                agents.isEmpty() -> Column(
                    Modifier.align(Alignment.Center).padding(32.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                ) {
                    Icon(Icons.Filled.SmartToy, contentDescription = null, tint = MaterialTheme.colorScheme.outline)
                    Spacer(Modifier.height(12.dp))
                    Text("还没有子代理", style = MaterialTheme.typography.titleMedium)
                    Spacer(Modifier.height(4.dp))
                    Text(
                        "子代理是拥有独立指令和技能子集的专家角色，\n可在主会话中通过 subagent_invoke 召唤。",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    Spacer(Modifier.height(16.dp))
                    OutlinedButton(onClick = { showImportDialog = true }) {
                        Text("导入 .md 定义")
                    }
                }
                else -> LazyColumn(
                    Modifier.fillMaxSize(),
                    contentPadding = PaddingValues(12.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    items(agents, key = { it.id }) { agent ->
                        AgentCard(
                            agent = agent,
                            onToggle = { enabled ->
                                scope.launch {
                                    subAgentRepository.setEnabled(agent.id, enabled)
                                    agents = subAgentRepository.listAll()
                                }
                            },
                            onDelete = {
                                scope.launch {
                                    subAgentRepository.delete(agent.id)
                                    agents = subAgentRepository.listAll()
                                }
                            },
                            onOpenSession = {
                                scope.launch {
                                    val model = subAgentRepository.modelOverride(agent.id) ?: defaultModelId
                                    val session = chatRepository.createSession(
                                        modelId = model,
                                        title = agent.name,
                                        subAgentId = agent.id,
                                    )
                                    onOpenSession(session.id)
                                }
                            },
                        )
                    }
                }
            }
        }
    }

    if (showImportDialog) {
        ImportAgentDialog(
            onDismiss = { showImportDialog = false },
            onImport = { content ->
                scope.launch {
                    val result = subAgentRepository.importFromContent(content)
                    snackbar = if (result != null) "已导入: ${result.name}" else "导入失败：缺少有效的 name 或 frontmatter"
                    agents = subAgentRepository.listAll()
                    showImportDialog = false
                }
            },
        )
    }
}

@Composable
private fun AgentCard(
    agent: SubAgentEntity,
    onToggle: (Boolean) -> Unit,
    onDelete: () -> Unit,
    onOpenSession: () -> Unit,
) {
    Card(
        modifier = Modifier.fillMaxWidth(),
        colors = CardDefaults.cardColors(),
    ) {
        Column(Modifier.padding(12.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text(agent.name, style = MaterialTheme.typography.titleMedium)
                    if (agent.description.isNotBlank()) {
                        Text(
                            agent.description,
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            maxLines = 2,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                    val meta = buildList {
                        if (agent.modelId != null) add("模型: ${agent.modelId}")
                        if (agent.skillsJson != "[]") add("技能: ${agent.skillsJson}")
                        add(if (agent.source == "builtin") "内置" else "导入")
                    }.joinToString(" · ")
                    if (meta.isNotBlank()) {
                        Text(
                            meta,
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.primary,
                        )
                    }
                }
                Switch(
                    checked = agent.isEnabled,
                    onCheckedChange = onToggle,
                )
            }
            Spacer(Modifier.height(8.dp))
            Row {
                OutlinedButton(onClick = onOpenSession, modifier = Modifier.height(36.dp)) {
                    Text("以会话打开")
                }
                Spacer(Modifier.width(8.dp))
                OutlinedButton(onClick = onDelete, modifier = Modifier.height(36.dp)) {
                    Text("删除")
                }
            }
        }
    }
}

@Composable
private fun ImportAgentDialog(
    onDismiss: () -> Unit,
    onImport: (String) -> Unit,
) {
    var content by remember { mutableStateOf("") }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("导入子代理") },
        text = {
            Column {
                Text(
                    "粘贴一个 Claude Code 格式的 agent 定义（YAML frontmatter：name/description/tools/model + 正文指令）：",
                    style = MaterialTheme.typography.bodySmall,
                )
                Spacer(Modifier.height(8.dp))
                OutlinedTextField(
                    value = content,
                    onValueChange = { content = it },
                    modifier = Modifier.fillMaxWidth().height(220.dp),
                    placeholder = { Text("---\nname: code-reviewer\ndescription: ...\ntools:\n  - python\ntools: []\n---\n\n你的指令...") },
                )
            }
        },
        confirmButton = {
            Button(onClick = { onImport(content) }, enabled = content.isNotBlank()) {
                Text("导入")
            }
        },
        dismissButton = {
            OutlinedButton(onClick = onDismiss) { Text("取消") }
        },
    )
}
