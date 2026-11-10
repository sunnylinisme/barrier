// SPDX-License-Identifier: GPL-2.0-or-later
#include "MSWindowsNativeDrag.h"
#include "MSWindowsNativeFileOffer.h"
#include "base/Log.h"

static thread_local NativeDragState* timerState = nullptr;
static void wakeDrag(NativeDragState* state)
{
    HWND capture = reinterpret_cast<HWND>(state->capture.load());
    POINT point = {}; GetCursorPos(&point);
    UINT message = state->pressed && !state->cancelled ? WM_MOUSEMOVE : WM_LBUTTONUP;
    WPARAM buttons = message == WM_MOUSEMOVE ? MK_LBUTTON : 0;
    if (capture) {
        ScreenToClient(capture, &point);
        PostMessageW(capture, message, buttons, MAKELPARAM(point.x, point.y));
    } else if (state->threadID) {
        PostThreadMessageW(state->threadID, message, buttons, MAKELPARAM(point.x, point.y));
    }
}
static void CALLBACK dragTick(HWND, UINT, UINT_PTR, DWORD)
{
    if (timerState) {
        timerState->capture = reinterpret_cast<std::uintptr_t>(GetCapture());
        wakeDrag(timerState);
    }
}
class RemoteDragSource final : public IDropSource {
public:
    explicit RemoteDragSource(std::shared_ptr<NativeDragState> state) : state_(std::move(state)), began_(GetTickCount64()) {}
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void** out) override {
        if (!out) return E_POINTER;
        *out = nullptr;
        if (iid != IID_IUnknown && iid != IID_IDropSource) return E_NOINTERFACE;
        *out = static_cast<IDropSource*>(this); AddRef(); return S_OK;
    }
    ULONG STDMETHODCALLTYPE AddRef() override { return InterlockedIncrement(&refs_); }
    ULONG STDMETHODCALLTYPE Release() override {
        LONG refs = InterlockedDecrement(&refs_); if (!refs) delete this; return refs;
    }
    HRESULT STDMETHODCALLTYPE QueryContinueDrag(BOOL escape, DWORD keys) override {
        LOG((CLOG_DEBUG2 "native drop: continue pressed=%d cancel=%d keys=%lu", int(state_->pressed.load()), int(state_->cancelled.load()), keys));
        if (escape || state_->cancelled || (keys & MK_RBUTTON) || GetTickCount64() - began_ > 60000)
            return DRAGDROP_S_CANCEL;
        if (state_->pressed) { armed_ = true; return S_OK; }
        // Releasing before the OLE loop starts must not drop into an unseen destination.
        return armed_ ? DRAGDROP_S_DROP : DRAGDROP_S_CANCEL;
    }
    HRESULT STDMETHODCALLTYPE GiveFeedback(DWORD) override { return DRAGDROP_S_USEDEFAULTCURSORS; }
private:
    LONG refs_ = 1;
    std::shared_ptr<NativeDragState> state_;
    ULONGLONG began_;
    bool armed_ = false;
};
MSWindowsNativeDrag::~MSWindowsNativeDrag() { cancel(); if (worker_.joinable()) worker_.join(); }
void MSWindowsNativeDrag::cancel() {
    if (state_) { state_->cancelled = true; wakeDrag(state_.get()); }
}
bool MSWindowsNativeDrag::release() {
    if (!state_ || state_->done) return false;
    state_->pressed = false; wakeDrag(state_.get()); return true;
}
void MSWindowsNativeDrag::start(std::shared_ptr<const barrier::NativeFile> file)
{
    if (state_ && !state_->done) { LOG((CLOG_WARN "native drop: previous drag is still active")); return; }
    if (worker_.joinable()) worker_.join();
    state_ = std::make_shared<NativeDragState>();
    auto state = state_;
    worker_ = std::thread([state, file]() {
        HRESULT init = OleInitialize(nullptr);
        if (FAILED(init)) { state->done = true; LOG((CLOG_ERR "native drop: OLE initialization failed")); return; }
        state->threadID = GetCurrentThreadId();
        timerState = state.get();
        LOG((CLOG_DEBUG "native drop: starting OLE loop"));
        auto offer = new FileOffer(file);
        auto source = new RemoteDragSource(state);
        // Timer also lets a disconnected/idle drag observe cancellation and its timeout.
        UINT_PTR timer = SetTimer(nullptr, 0, 100, dragTick);
        DWORD effect = DROPEFFECT_NONE;
        HRESULT result = timer ? DoDragDrop(offer, source, DROPEFFECT_COPY, &effect) : E_FAIL;
        if (timer) KillTimer(nullptr, timer);
        timerState = nullptr;
        source->Release(); offer->Release();
        OleUninitialize(); state->done = true;
        LOG((CLOG_INFO "native drop: %s (HRESULT %lx)",
             result == DRAGDROP_S_DROP && (effect & DROPEFFECT_COPY) ? "copy accepted" : "cancelled or rejected", static_cast<unsigned long>(result)));
    });
}
