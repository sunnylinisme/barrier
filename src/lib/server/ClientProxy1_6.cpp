/*
 * barrier -- mouse and keyboard sharing utility
 * Copyright (C) 2015-2016 Symless Ltd.
 *
 * This package is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public License
 * found in the file LICENSE that should have accompanied this file.
 *
 * This package is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */

#include "server/ClientProxy1_6.h"

#include "server/Server.h"
#include "barrier/ProtocolUtil.h"
#include "barrier/StreamChunker.h"
#include "barrier/ClipboardChunk.h"
#include "io/IStream.h"
#include "base/TMethodEventJob.h"
#include "base/Log.h"
#include "barrier/App.h"
#include "barrier/ArgsBase.h"

//
// ClientProxy1_6
//

ClientProxy1_6::ClientProxy1_6(const std::string& name, barrier::IStream* stream, Server* server,
                               IEventQueue* events) :
    ClientProxy1_5(name, stream, server, events),
    m_events(events)
{
    m_filesEnabled = App::instance().argsBase().m_fileClipboard;
    m_files.reset(new barrier::AsyncFileClipboardTransfer(getStream(), [this](ClipboardID id, uint32_t sequence, const std::string& handle) {
        auto& target = m_clipboard[id];
        target.m_clipboard.open(0); target.m_clipboard.empty(); target.m_clipboard.add(IClipboard::kFile, handle); target.m_clipboard.close();
        target.m_sequenceNumber = sequence;
        auto info = new ClipboardInfo; info->m_id = id; info->m_sequenceNumber = sequence;
        m_events->addEvent(Event(m_events->forClipboard().clipboardChanged(), getEventTarget(), info));
    }, events));
    // Empty the clipboard while the files arrive, so a paste meanwhile cannot paste older content.
    m_files->onIncoming([this](ClipboardID id, uint32_t sequence) {
        auto& target = m_clipboard[id];
        target.m_clipboard.open(0); target.m_clipboard.empty(); target.m_clipboard.close();
        target.m_sequenceNumber = sequence;
        auto info = new ClipboardInfo; info->m_id = id; info->m_sequenceNumber = sequence;
        m_events->addEvent(Event(m_events->forClipboard().clipboardChanged(), getEventTarget(), info));
        LOG((CLOG_INFO "file clipboard: cleared local clipboard until the files arrive"));
    });
    m_events->adoptHandler(m_events->forClipboard().clipboardSending(),
                                this,
                                new TMethodEventJob<ClientProxy1_6>(this,
                                    &ClientProxy1_6::handleClipboardSendingEvent));
}

ClientProxy1_6::~ClientProxy1_6()
{
    m_events->removeHandler(m_events->forClipboard().clipboardSending(), this);
}

bool ClientProxy1_6::parseMessage(const UInt8* code)
{
    if (memcmp(code, barrier::fileClipboardCapability, 4) == 0) {
        UInt32 version = 0;
        if (!ProtocolUtil::readf(getStream(), barrier::fileClipboardCapability + 4, &version)) return false;
        m_filesReady = m_filesEnabled && version == 2;
        ProtocolUtil::writef(getStream(), barrier::fileClipboardCapability, m_filesReady ? 2 : 0);
        LOG((CLOG_INFO "file clipboard: peer %s", m_filesReady ? "ready (streaming v2)" : "requires matching version"));
        return true;
    }
    if (memcmp(code, "FC", 2) == 0) return m_filesReady && m_files->receive(code);
    return ClientProxy1_5::parseMessage(code);
}

void ClientProxy1_6::grabClipboard(ClipboardID id)
{
    if (m_filesEnabled && id != kClipboardClipboard) return;
    if (id == kClipboardClipboard) m_files->cancel();
    ClientProxy1_5::grabClipboard(id);
}

void
ClientProxy1_6::setClipboard(ClipboardID id, const IClipboard* clipboard)
{
    if (m_filesEnabled && id != kClipboardClipboard) return;
    // ignore if this clipboard is already clean
    if (m_clipboard[id].m_dirty) {
        // this clipboard is now clean
        m_clipboard[id].m_dirty = false;
        Clipboard::copy(&m_clipboard[id].m_clipboard, clipboard);

        const auto& local = m_clipboard[id].m_clipboard;
        if (local.has(IClipboard::kFile)) {
            if (!m_filesReady) { LOG((CLOG_WARN "file clipboard: update both computers to the streaming version")); return; }
            try { m_files->start(local.get(IClipboard::kFile), id, 0); }
            catch (const std::exception& e) { LOG((CLOG_WARN "file clipboard: %s", e.what())); }
            return;
        }
        if (id == kClipboardClipboard) m_files->cancel();

        std::string data = m_clipboard[id].m_clipboard.marshall();

        size_t size = data.size();
        LOG((CLOG_DEBUG "sending clipboard %d to \"%s\"", id, getName().c_str()));

        StreamChunker::sendClipboard(data, size, id, 0, m_events, this);
    }
}

void
ClientProxy1_6::handleClipboardSendingEvent(const Event& event, void*)
{
    ClipboardChunk::send(getStream(), event.getData());
}

bool
ClientProxy1_6::recvClipboard()
{
    // parse message
    static std::string dataCached;
    ClipboardID id;
    UInt32 seq;

    int r = ClipboardChunk::assemble(getStream(), dataCached, id, seq);

    if (r == kStart) {
        size_t size = ClipboardChunk::getExpectedSize();
        LOG((CLOG_DEBUG "receiving clipboard %d size=%d", id, size));
    }
    else if (r == kFinish) {
        LOG((CLOG_DEBUG "received client \"%s\" clipboard %d seqnum=%d, size=%d",
                getName().c_str(), id, seq, dataCached.size()));
        // save clipboard
        m_clipboard[id].m_clipboard.unmarshall(dataCached, 0);
        // Local file handles must never be supplied through the legacy wire format.
        if (m_clipboard[id].m_clipboard.has(IClipboard::kFile)) return false;
        m_clipboard[id].m_sequenceNumber = seq;

        // notify
        ClipboardInfo* info = new ClipboardInfo;
        info->m_id = id;
        info->m_sequenceNumber = seq;
        m_events->addEvent(Event(m_events->forClipboard().clipboardChanged(),
                                 getEventTarget(), info));
    }

    return true;
}
