/** Test hosts only: Windows may allocate a port forbidden by Fetch itself. */
export async function listenForFetch(server) {
  for(let attempt=0;attempt<10;attempt++) {
    await new Promise((resolve,reject)=>{
      server.once('error',reject);
      server.listen(0,'127.0.0.1',()=>{server.removeListener('error',reject);resolve();});
    });
    try {
      // HEAD cannot create orders or change financial state.
      await fetch('http://127.0.0.1:'+server.address().port+'/__go_test_network_probe',{method:'HEAD'});
      return;
    } catch(error) {
      await new Promise(resolve=>server.close(resolve));
      if(error.cause?.message!=='bad port')throw error;
    }
  }
  throw new Error('Cannot allocate a Fetch-compatible TEST loopback port');
}
