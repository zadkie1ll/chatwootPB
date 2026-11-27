import fs from 'node:fs';
import vm from 'node:vm';

const source = fs.readFileSync('public/sw.js', 'utf8');
const worker = () => {
  const listeners = {};
  const show = vi.fn().mockResolvedValue();
  const fetch = vi.fn().mockResolvedValue({ ok: true });
  vm.runInNewContext(source, {
    URL,
    fetch,
    self: {
      location: { origin: 'https://mess.example.invalid' },
      registration: { showNotification: show },
      addEventListener: (event, callback) => {
        listeners[event] = callback;
      },
    },
  });
  return { listeners, show, fetch };
};

describe('Corporate push service worker', () => {
  it('acknowledges a test only after the browser accepts showNotification', async () => {
    const { listeners, show, fetch } = worker();
    let finished;
    show.mockImplementation(
      () =>
        new Promise(resolve => {
          finished = resolve;
        })
    );
    let work;
    listeners.push({
      data: {
        json: () => ({
          title: 'Synthetic',
          type: 'corporate_test',
          receipt_token: 'signed-test',
        }),
      },
      waitUntil: promise => {
        work = promise;
      },
    });
    expect(fetch).not.toHaveBeenCalled();
    finished();
    await work;
    expect(fetch).toHaveBeenCalledWith(
      '/api/v1/corporate_push_receipts',
      expect.objectContaining({
        credentials: 'omit',
        body: JSON.stringify({ token: 'signed-test' }),
      })
    );
  });
  it('does not acknowledge a notification rejected by the browser', async () => {
    const { listeners, show, fetch } = worker();
    show.mockRejectedValue(new Error('Blocked'));
    let work;
    listeners.push({
      data: {
        json: () => ({
          title: 'Synthetic',
          type: 'corporate_test',
          receipt_token: 'test',
        }),
      },
      waitUntil: promise => {
        work = promise;
      },
    });
    await expect(work).rejects.toThrow('Blocked');
    expect(fetch).not.toHaveBeenCalled();
  });
  it('keeps notification click targets on this origin', async () => {
    const { listeners, show } = worker();
    let work;
    listeners.push({
      data: {
        json: () => ({
          title: 'Synthetic',
          url: 'https://other.example.invalid/',
        }),
      },
      waitUntil: promise => {
        work = promise;
      },
    });
    await work;
    expect(show).toHaveBeenCalledWith(
      'Synthetic',
      expect.objectContaining({
        data: { url: 'https://mess.example.invalid/app' },
      })
    );
  });
});
