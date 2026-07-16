package com.example.tin_can

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.graphics.BitmapFactory
import android.graphics.Color
import android.net.Uri
import android.view.View
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetLaunchIntent
import es.antonborri.home_widget.HomeWidgetPlugin
import org.json.JSONArray
import org.json.JSONObject

// ---------------------------------------------------------------------------
//  Widżety Tin Can. Dane (obrazy/podpisy/mapowania) zapisuje strona Flutter
//  przez home_widget (lib/widget_bridge.dart). Klik niesie uri
//  tincan://chat/<peerId>?label=... i otwiera czat z tą osobą w apce.
// ---------------------------------------------------------------------------

private fun chatIntent(context: Context, peerId: String, label: String): PendingIntent {
    val uri = Uri.parse("tincan://chat/$peerId?label=${Uri.encode(label)}")
    return HomeWidgetLaunchIntent.getActivity(context, MainActivity::class.java, uri)
}

// --- Widżet z rysunkiem (kwadrat). ------------------------------------------
abstract class BaseDrawingWidget : AppWidgetProvider() {
    override fun onUpdate(
        context: Context,
        manager: AppWidgetManager,
        ids: IntArray,
    ) {
        val prefs = HomeWidgetPlugin.getData(context)
        // Motyw z apki: kolor płótna (jak w czacie rysunkowym) + tryb ciemny.
        // Płótno = jeden z 4 znanych kolorów -> gotowy ZAOKRĄGLONY drawable
        // (setBackgroundColor gubił zaokrąglenie rogów).
        val dark = prefs.getBoolean("widget_dark", false)
        val canvasRes = when (prefs.getString("widget_canvas", "#fbf8f1")?.lowercase()) {
            "#ffffff" -> R.drawable.widget_canvas_bg
            "#14101f" -> R.drawable.widget_canvas_night
            "#000000" -> R.drawable.widget_canvas_black
            else -> R.drawable.widget_canvas_paper
        }
        val captionColor = if (dark) Color.parseColor("#A39DBE") else Color.parseColor("#55506A")
        for (id in ids) {
            // Mapowanie instancja -> osoba; nowa instancja przejmuje "pending"
            // (konfigurację zapisaną w apce tuż przed przypięciem widżetu).
            var personJson = prefs.getString("widget_person_$id", null)
            if (personJson == null) {
                val pending = prefs.getString("pending_widget_person", null)
                if (pending != null) {
                    prefs.edit()
                        .putString("widget_person_$id", pending)
                        .remove("pending_widget_person")
                        .apply()
                    personJson = pending
                }
            }

            val views = RemoteViews(context.packageName, R.layout.tin_can_widget_drawing)
            // Chrom widżetu podąża za motywem apki: karta jasna/ciemna, wnętrze
            // płótna = kolor wybrany w apce, podpisy w kontraście do karty.
            views.setInt(
                R.id.widget_root, "setBackgroundResource",
                if (dark) R.drawable.widget_bg_dark else R.drawable.widget_bg)
            views.setInt(R.id.widget_canvas, "setBackgroundResource", canvasRes)
            views.setTextColor(R.id.widget_caption, captionColor)
            views.setTextColor(R.id.widget_empty, captionColor)
            var configured = false
            if (personJson != null) {
                try {
                    val person = JSONObject(personJson)
                    val peerId = person.getString("id")
                    val label = person.optString("label", "")
                    val imgPath = prefs.getString("widget_img_$peerId", null)
                    val caption = prefs.getString("widget_caption_$peerId", label) ?: label

                    var hasImage = false
                    if (imgPath != null) {
                        val bmp = BitmapFactory.decodeFile(imgPath)
                        if (bmp != null) {
                            views.setImageViewBitmap(R.id.widget_image, bmp)
                            hasImage = true
                        }
                    }
                    views.setViewVisibility(
                        R.id.widget_image, if (hasImage) View.VISIBLE else View.GONE)
                    views.setViewVisibility(
                        R.id.widget_empty, if (hasImage) View.GONE else View.VISIBLE)
                    if (!hasImage) {
                        views.setTextViewText(
                            R.id.widget_empty, "Tu wyląduje rysunek od $label 🥫")
                    }
                    views.setTextViewText(R.id.widget_caption, caption)
                    views.setOnClickPendingIntent(
                        R.id.widget_root, chatIntent(context, peerId, label))
                    configured = true
                } catch (_: Exception) {
                    // uszkodzona konfiguracja -> stan "nieskonfigurowany" niżej
                }
            }
            if (!configured) {
                views.setViewVisibility(R.id.widget_image, View.GONE)
                views.setViewVisibility(R.id.widget_empty, View.VISIBLE)
                views.setTextViewText(
                    R.id.widget_empty,
                    "Otwórz Tin Can i dodaj widżet z menu znajomego (⋮)")
                views.setTextViewText(R.id.widget_caption, "Tin Can")
            }
            manager.updateAppWidget(id, views)
        }
    }

    override fun onDeleted(context: Context, ids: IntArray) {
        val ed = HomeWidgetPlugin.getData(context).edit()
        for (id in ids) ed.remove("widget_person_$id")
        ed.apply()
    }
}

class TinCanDrawingWidgetProvider : BaseDrawingWidget()

// --- Pasek "szybkie czaty": do 5 ikonek, każda otwiera czat z osobą. --------
class TinCanChatsWidgetProvider : AppWidgetProvider() {
    override fun onUpdate(
        context: Context,
        manager: AppWidgetManager,
        ids: IntArray,
    ) {
        val prefs = HomeWidgetPlugin.getData(context)
        val dark = prefs.getBoolean("widget_dark", false)
        val arr = try {
            JSONArray(prefs.getString("chats_widget", "[]") ?: "[]")
        } catch (_: Exception) {
            JSONArray()
        }
        val slots = intArrayOf(
            R.id.chat_slot_1, R.id.chat_slot_2, R.id.chat_slot_3,
            R.id.chat_slot_4, R.id.chat_slot_5,
        )
        val initials = intArrayOf(
            R.id.chat_initial_1, R.id.chat_initial_2, R.id.chat_initial_3,
            R.id.chat_initial_4, R.id.chat_initial_5,
        )
        for (id in ids) {
            val views = RemoteViews(context.packageName, R.layout.tin_can_widget_chats)
            views.setInt(
                R.id.chats_root, "setBackgroundResource",
                if (dark) R.drawable.widget_bg_dark else R.drawable.widget_bg)
            views.setTextColor(
                R.id.chats_empty,
                if (dark) Color.parseColor("#A39DBE") else Color.parseColor("#55506A"))
            for (i in slots.indices) {
                if (i < arr.length()) {
                    val o = arr.getJSONObject(i)
                    views.setViewVisibility(slots[i], View.VISIBLE)
                    views.setTextViewText(initials[i], o.optString("initial", "?"))
                    views.setOnClickPendingIntent(
                        slots[i],
                        chatIntent(context, o.getString("id"), o.optString("label", "")),
                    )
                } else {
                    views.setViewVisibility(slots[i], View.GONE)
                }
            }
            views.setViewVisibility(
                R.id.chats_empty,
                if (arr.length() == 0) View.VISIBLE else View.GONE,
            )
            manager.updateAppWidget(id, views)
        }
    }
}
