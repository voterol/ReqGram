"""Bundled trusted smoke test. No accounts, messages, or network access."""
import collections
import json
import sys
import reqgram_host

def run():
    assert sys.platform == 'ios', sys.platform
    assert sys.flags.isolated and sys.dont_write_bytecode
    assert len(sys.path) == 2 and all('.bundle' in p for p in sys.path)
    assert reqgram_host.lifecycle() == 'enabled'
    previous = reqgram_host.load()
    reqgram_host.save(b'reqgram-smoke-v1')
    assert reqgram_host.load() == b'reqgram-smoke-v1'
    try:
        reqgram_host.save(b'x' * 65537)
    except ValueError:
        pass
    else:
        raise AssertionError('storage limit not enforced')
    reqgram_host.log('bundled Python smoke passed')
    return json.dumps(dict(expression=6 * 7, pure_module=collections.Counter('banana')['a'],
                           platform=sys.platform, version=sys.version.split()[0],
                           persisted=previous == b'reqgram-smoke-v1'), sort_keys=True)

def run_disabled():
    assert reqgram_host.lifecycle() == 'disabled'
    for operation in (reqgram_host.load, lambda: reqgram_host.save(b'disabled')):
        try:
            operation()
        except RuntimeError:
            pass
        else:
            raise AssertionError('disabled runtime host operation was allowed')
    return 'disabled host operations blocked'
