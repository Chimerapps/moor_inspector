package com.chimerapps.moorinspector.ui.view

import com.chimerapps.moorinspector.client.MoorInspectorMessageListener
import com.chimerapps.moorinspector.client.protocol.MoorInspectorServerInfo
import com.chimerapps.moorinspector.ui.util.IncludedIcons
import com.chimerapps.moorinspector.ui.util.ensureMain
import com.chimerapps.moorinspector.ui.util.localization.Tr
import com.intellij.ui.components.JBLabel
import java.awt.BorderLayout
import javax.swing.BorderFactory
import javax.swing.JPanel
import javax.swing.border.EmptyBorder

class MoorInspectorStatusBar : JPanel(BorderLayout()), MoorInspectorMessageListener {

    private val statusText = JBLabel().apply {
        isFocusable = false
        text = ""
        verifyInputWhenFocusTarget = false
    }

    private var status: Status = Status.DISCONNECTED
    private var serverInfo: MoorInspectorServerInfo? = null

    init {
        add(statusText, BorderLayout.CENTER)
        border = BorderFactory.createCompoundBorder(
            BorderFactory.createTitledBorder(
                BorderFactory.createLoweredBevelBorder(),
                null
            ), EmptyBorder(1, 6, 1, 6)
        )
        updateStatusText()
        updateStatusIcon()
    }

    override fun onServerInfo(serverInfo: MoorInspectorServerInfo) {
        this.serverInfo = serverInfo
        updateStatusText()
    }

    override fun onReady() {
        status = Status.CONNECTED
        updateStatusIcon()
    }

    override fun onClosed() {
        status = Status.DISCONNECTED
        serverInfo = null
        updateStatusIcon()
        updateStatusText()
    }

    private fun updateStatusText() {
        val text = when (status) {
            Status.CONNECTED -> buildText(Tr.StatusConnected.tr(), Tr.StatusConnectedTo.tr())
            Status.DISCONNECTED -> Tr.StatusDisconnected.tr()
        }
        ensureMain {
            statusText.text = text
        }
    }

    private fun updateStatusIcon() {
        ensureMain {
            statusText.icon = when (status) {
                Status.CONNECTED -> IncludedIcons.Status.connected
                Status.DISCONNECTED -> IncludedIcons.Status.disconnected
            }
        }
    }

    @Suppress("SameParameterValue")
    private fun buildText(prefix: String, glue: String): String {
        val builder = StringBuilder()
        builder.append(prefix)
        serverInfo?.let {
            builder.append(' ').append(glue).append(' ')
                .append(it.bundleId)
                .append(" (").append(it.databases.size)
                .append(" database(s) - ${it.databases.sumBy { db -> db.structure.tables.size }} table(s)) - V")
                .append(it.protocolVersion)
        }
        return builder.toString()
    }

    private enum class Status {
        CONNECTED, DISCONNECTED
    }

}