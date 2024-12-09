package com.twilio.twilio_voice.call
class MapEntry(val key: String, val value: Any)

class MapConverter {
    private val entries = mutableListOf<MapEntry>()

    fun add(key: String, value: Any) {
        entries.add(MapEntry(key, value))
    }

    operator fun get(key: String): Any? {
        return entries.find { it.key == key }?.value
    }

    fun size(): Int {
        return entries.size
    }

    override fun toString(): String {
        return entries.toString()
    }
}