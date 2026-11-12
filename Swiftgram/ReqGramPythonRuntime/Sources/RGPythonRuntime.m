#import "RGPythonRuntime.h"
#include <Python/Python.h>

static BOOL enabled = YES;
static NSURL *storageURL;
static NSError *RGError(NSString *message) {
    return [NSError errorWithDomain:@"ReqGramPythonRuntime" code:1 userInfo:@{NSLocalizedDescriptionKey: message}];
}
static PyObject *hostLog(PyObject *self, PyObject *args) {
    const char *text;
    if (!PyArg_ParseTuple(args, "s", &text)) return NULL;
    if (strlen(text) > 4096) return PyErr_Format(PyExc_ValueError, "log exceeds 4096 bytes");
    NSLog(@"[ReqGramPython] %@", [NSString stringWithUTF8String:text]);
    Py_RETURN_NONE;
}
static PyObject *hostLoad(PyObject *self, PyObject *args) {
    if (!enabled) return PyErr_Format(PyExc_RuntimeError, "runtime execution is disabled");
    NSError *error = nil;
    NSData *data = [NSData dataWithContentsOfURL:storageURL options:0 error:&error];
    if (!data && error.code == NSFileReadNoSuchFileError) Py_RETURN_NONE;
    if (!data) return PyErr_Format(PyExc_OSError, "runtime storage read failed");
    if (data.length > 65536) return PyErr_Format(PyExc_ValueError, "runtime storage exceeds limit");
    return PyBytes_FromStringAndSize(data.bytes, data.length);
}
static PyObject *hostSave(PyObject *self, PyObject *args) {
    if (!enabled) return PyErr_Format(PyExc_RuntimeError, "runtime execution is disabled");
    const char *bytes; Py_ssize_t length;
    if (!PyArg_ParseTuple(args, "y#", &bytes, &length)) return NULL;
    if (length > 65536) return PyErr_Format(PyExc_ValueError, "runtime storage exceeds 65536 bytes");
    NSError *error = nil;
    if (![[NSFileManager defaultManager] createDirectoryAtURL:storageURL.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:&error] ||
        ![[NSData dataWithBytes:bytes length:length] writeToURL:storageURL options:NSDataWritingAtomic error:&error])
        return PyErr_Format(PyExc_OSError, "runtime storage write failed");
    Py_RETURN_NONE;
}
static PyObject *hostLifecycle(PyObject *self, PyObject *args) { return PyUnicode_FromString(enabled ? "enabled" : "disabled"); }
static PyMethodDef methods[] = {
    {"log", hostLog, METH_VARARGS, "Write a bounded native diagnostic log."},
    {"load", hostLoad, METH_NOARGS, "Read runtime-owned bytes or None; not plugin-manager storage."},
    {"save", hostSave, METH_VARARGS, "Atomically persist at most 64 KiB of runtime-owned bytes."},
    {"lifecycle", hostLifecycle, METH_NOARGS, "Return the native execution gate."},
    {NULL, NULL, 0, NULL}
};
static struct PyModuleDef hostModule = {PyModuleDef_HEAD_INIT, "reqgram_host", NULL, -1, methods};
static PyObject *PyInit_reqgram_host(void) { return PyModule_Create(&hostModule); }

typedef NSDictionary *(^RGHost)(NSString *, NSData *);
static void releaseHost(PyObject *capsule) { CFRelease(PyCapsule_GetPointer(capsule, "reqgram.host")); }
static PyObject *pluginHost(PyObject *self, PyObject *args) {
    const char *operation; PyObject *payload = Py_None;
    if (!PyArg_ParseTuple(args, "s|O", &operation, &payload)) return NULL;
    NSData *data = nil;
    if (payload != Py_None) {
        if (!PyBytes_Check(payload)) return PyErr_Format(PyExc_TypeError, "payload must be bytes");
        if (PyBytes_Size(payload) > 65536) return PyErr_Format(PyExc_ValueError, "payload exceeds 64 KiB");
        data = [NSData dataWithBytes:PyBytes_AsString(payload) length:PyBytes_Size(payload)];
    }
    RGHost host = (__bridge RGHost)PyCapsule_GetPointer(self, "reqgram.host");
    if (!host) return NULL;
    NSDictionary *result = host([NSString stringWithUTF8String:operation], data);
    if (result[@"error"]) {
        NSData *json = [NSJSONSerialization dataWithJSONObject:@{@"operation": [NSString stringWithUTF8String:operation], @"error": result[@"error"]} options:0 error:nil];
        NSString *message = [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
        return PyErr_Format(PyExc_RuntimeError, "%s", message.UTF8String);
    }
    NSData *value = result[@"data"];
    if (!value) Py_RETURN_NONE;
    return PyBytes_FromStringAndSize(value.bytes, value.length);
}
static PyMethodDef pluginMethod = {"request", pluginHost, METH_VARARGS, "Plugin-bound host callback"};

@implementation RGPythonRuntime {
    dispatch_queue_t _queue;
    BOOL _ready;
    NSError *_initializationError;
}
+ (instancetype)shared {
    static RGPythonRuntime *runtime; static dispatch_once_t once;
    dispatch_once(&once, ^{ runtime = [[self alloc] initPrivate]; });
    return runtime;
}
- (instancetype)initPrivate {
    if ((self = [super init])) _queue = dispatch_queue_create("reqgram.python.runtime", DISPATCH_QUEUE_SERIAL);
    return self;
}
- (NSError *)initializePython {
    if (_ready) return nil;
    if (_initializationError) return _initializationError;
    // The main client links this class into TelegramUIFramework; its resource
    // bundle lives beside that framework, not necessarily at the app root.
    NSURL *bundleURL = [[NSBundle bundleForClass:[RGPythonRuntime class]] URLForResource:@"ReqGramPythonResources" withExtension:@"bundle"];
    if (!bundleURL) bundleURL = [[NSBundle mainBundle] URLForResource:@"ReqGramPythonResources" withExtension:@"bundle"];
    NSBundle *bundle = bundleURL ? [NSBundle bundleWithURL:bundleURL] : nil;
    NSString *zip = [bundle pathForResource:@"python313" ofType:@"zip"];
    NSString *module = [bundle pathForResource:@"reqgram_smoke" ofType:@"py"];
    if (!zip || !module) return RGError(@"Missing bundled Python resources; run third-party/PythonRuntime/prepare.py before building.");
    storageURL = [[[NSFileManager defaultManager] URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject URLByAppendingPathComponent:@"ReqGramPythonRuntime/host.bin"];
    if (Py_IsInitialized()) return RGError(@"Another component already owns CPython.");
    PyPreConfig pre; PyPreConfig_InitIsolatedConfig(&pre); pre.utf8_mode = 1;
    PyStatus status = Py_PreInitialize(&pre);
    if (!PyStatus_Exception(status) && PyImport_AppendInittab("reqgram_host", PyInit_reqgram_host) < 0)
        status = PyStatus_Error("Cannot register reqgram_host");
    PyConfig config; PyConfig_InitIsolatedConfig(&config);
    config.site_import = 0; config.write_bytecode = 0; config.buffered_stdio = 0;
    // Embedded application owns signals. Unlike the CPython testbed, never install handlers.
    config.install_signal_handlers = 0;
    config.module_search_paths_set = 1;
    if (!PyStatus_Exception(status)) status = PyConfig_SetBytesString(&config, &config.home, bundle.resourcePath.UTF8String);
    for (NSString *path in @[zip, module.stringByDeletingLastPathComponent]) {
        if (PyStatus_Exception(status)) break;
        wchar_t *wide = Py_DecodeLocale(path.UTF8String, NULL);
        if (!wide) { status = PyStatus_NoMemory(); break; }
        status = PyWideStringList_Append(&config.module_search_paths, wide); PyMem_RawFree(wide);
    }
    if (!PyStatus_Exception(status)) status = Py_InitializeFromConfig(&config);
    if (PyStatus_Exception(status)) _initializationError = RGError(status.err_msg ? [NSString stringWithUTF8String:status.err_msg] : @"CPython initialization failed");
    PyConfig_Clear(&config);
    if (_initializationError) return _initializationError;
    _ready = YES;
    PyEval_SaveThread(); // Queue blocks may run on different native threads.
    return nil;
}
- (void)setExecutionEnabled:(BOOL)value { dispatch_async(_queue, ^{ enabled = value; }); }
- (void)runPlugin:(NSString *)moduleName directory:(NSString *)directory start:(BOOL)start host:(RGHost)host boundary:(BOOL (^)(BOOL))boundary completion:(void (^)(NSError *))completion {
    dispatch_async(_queue, ^{
        NSError *error = [self initializePython];
        if (!error && !boundary(YES)) error = RGError(@"Could not persist execution marker or execution is blocked.");
        if (!error) {
            PyGILState_STATE gil = PyGILState_Ensure();
            PyObject *modules = PyImport_GetModuleDict();
            PyObject *module = PyDict_GetItemString(modules, moduleName.UTF8String);
            Py_XINCREF(module);
            if (start && module) { error = RGError(@"Plugin is already loaded."); }
            else if (start) {
                module = PyModule_New(moduleName.UTF8String);
                if (module) {
                    PyObject *globals = PyModule_GetDict(module);
                    PyObject *capsule = PyCapsule_New((void *)CFBridgingRetain([host copy]), "reqgram.host", releaseHost);
                    PyObject *callback = capsule ? PyCFunction_New(&pluginMethod, capsule) : NULL;
                    Py_XDECREF(capsule);
                    NSString *path = [directory stringByAppendingPathComponent:@"main.py"];
                    NSData *source = [NSData dataWithContentsOfFile:path];
                    PyObject *file = PyUnicode_FromString(path.UTF8String);
                    BOOL configured = callback && file && PyDict_SetItemString(globals, "host_request", callback) == 0 && PyDict_SetItemString(globals, "__file__", file) == 0 && PyDict_SetItemString(modules, moduleName.UTF8String, module) == 0;
                    Py_XDECREF(callback); Py_XDECREF(file);
                    NSMutableData *terminated = [source mutableCopy]; [terminated appendBytes:"\0" length:1];
                    PyObject *code = configured && source ? Py_CompileString(terminated.bytes, path.UTF8String, Py_file_input) : NULL;
                    PyObject *result = code ? PyEval_EvalCode(code, globals, globals) : NULL;
                    Py_XDECREF(code);
                    if (result) {
                        Py_DECREF(result);
                        PyObject *hook = PyObject_GetAttrString(module, "on_enable");
                        result = hook ? PyObject_CallNoArgs(hook) : NULL;
                        Py_XDECREF(hook);
                    }
                    if (!result && !PyErr_Occurred()) PyErr_SetString(PyExc_RuntimeError, "Cannot load main.py");
                    Py_XDECREF(result);
                }
            } else if (module) {
                PyObject *hook = PyObject_GetAttrString(module, "on_disable");
                PyObject *result = hook ? PyObject_CallNoArgs(hook) : NULL;
                Py_XDECREF(result); Py_XDECREF(hook);
            }
            if (PyErr_Occurred()) {
                PyObject *exception = PyErr_GetRaisedException();
                PyObject *text = exception ? PyObject_Str(exception) : NULL;
                const char *message = text ? PyUnicode_AsUTF8(text) : NULL;
                error = RGError(message ? [NSString stringWithUTF8String:message] : @"Plugin execution failed");
                Py_XDECREF(text); Py_XDECREF(exception); PyErr_Clear();
            }
            // Persistence is part of the execution result. Decide residency only
            // after it succeeds, otherwise the manager forgets a resident module.
            PyGILState_Release(gil);
            if (!boundary(NO)) error = RGError(@"Execution finished but recovery marker could not be cleared.");
            gil = PyGILState_Ensure();
            if (!start || error) { if (PyDict_DelItemString(modules, moduleName.UTF8String) < 0) PyErr_Clear(); }
            Py_XDECREF(module);
            PyGILState_Release(gil);
        } else if (!start && self->_ready) {
            // A retained recovery marker can refuse teardown's Python entry.
            // Still release residency: the executor has already closed native
            // capabilities. Do not call on_disable or either boundary again.
            PyGILState_STATE gil = PyGILState_Ensure();
            if (PyDict_DelItemString(PyImport_GetModuleDict(), moduleName.UTF8String) < 0) PyErr_Clear();
            PyGILState_Release(gil);
        }
        dispatch_async(dispatch_get_main_queue(), ^{ completion(error); });
    });
}
- (void)deliverEvent:(NSString *)moduleName takeEvent:(NSData *(^)(void))takeEvent boundary:(BOOL (^)(BOOL))boundary completion:(void (^)(NSError *))completion {
    dispatch_async(_queue, ^{
        @autoreleasepool {
            NSError *error = nil;
            if (!self->_ready || !enabled) { completion(RGError(@"Event runtime unavailable")); return; }
            if (!boundary(YES)) { completion(RGError(@"Event execution boundary refused")); return; }
            PyGILState_STATE gil = PyGILState_Ensure();
            // Admission occurs here, not when this queue block was scheduled.
            NSData *bytes = takeEvent();
            if (bytes) {
                PyObject *module = PyDict_GetItemString(PyImport_GetModuleDict(), moduleName.UTF8String);
                PyObject *hook = module ? PyObject_GetAttrString(module, "on_event") : NULL;
                PyObject *json = PyImport_ImportModule("json");
                PyObject *loads = json ? PyObject_GetAttrString(json, "loads") : NULL;
                PyObject *payload = PyBytes_FromStringAndSize(bytes.bytes, bytes.length);
                PyObject *event = loads && payload ? PyObject_CallOneArg(loads, payload) : NULL;
                PyObject *result = hook && event ? PyObject_CallOneArg(hook, event) : NULL;
                // Do not stringify untrusted exceptions (which can execute more Python),
                // or log event bodies. Includes BaseException/SystemExit.
                if (!result || PyErr_Occurred() || PyCoro_CheckExact(result) || PyGen_Check(result) || PyAsyncGen_CheckExact(result)) error = RGError(@"on_event failed; delivery suspended until re-enable");
                Py_XDECREF(result); Py_XDECREF(event); Py_XDECREF(payload);
                Py_XDECREF(loads); Py_XDECREF(json); Py_XDECREF(hook);
                PyErr_Clear();
            }
            PyGILState_Release(gil);
            if (!boundary(NO)) error = RGError(@"Event recovery marker could not be cleared; delivery suspended");
            completion(error);
        }
    });
}
- (void)evaluateExpression:(NSString *)expression completion:(void (^)(NSString *, NSError *))completion {
    NSString *source = [expression copy];
    dispatch_async(_queue, ^{
        @autoreleasepool {
            NSError *error = enabled ? [self initializePython] : RGError(@"Runtime execution is disabled.");
            NSString *result = nil;
            if (!error && ([source lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 65536 || [source rangeOfString:[NSString stringWithFormat:@"%C", (unichar)0]].location != NSNotFound)) error = RGError(@"Invalid expression size or embedded NUL.");
            if (!error) {
                PyGILState_STATE gil = PyGILState_Ensure();
                PyObject *globals = PyDict_New();
                PyObject *value = NULL;
                if (globals && PyDict_SetItemString(globals, "__builtins__", PyEval_GetBuiltins()) == 0)
                    value = PyRun_StringFlags(source.UTF8String, Py_eval_input, globals, globals, NULL);
                PyObject *text = value ? PyObject_Str(value) : NULL;
                const char *utf8 = text ? PyUnicode_AsUTF8(text) : NULL;
                if (utf8) result = [NSString stringWithUTF8String:utf8];
                else {
                    PyObject *exception = PyErr_GetRaisedException();
                    PyObject *description = exception ? PyObject_Str(exception) : NULL;
                    const char *message = description ? PyUnicode_AsUTF8(description) : NULL;
                    error = RGError(message ? [NSString stringWithUTF8String:message] : @"Python evaluation failed");
                    Py_XDECREF(description); Py_XDECREF(exception); PyErr_Clear();
                }
                Py_XDECREF(text); Py_XDECREF(value); Py_XDECREF(globals);
                PyGILState_Release(gil);
            }
            dispatch_async(dispatch_get_main_queue(), ^{ completion(result, error); });
        }
    });
}
@end
