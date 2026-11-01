 # INFO1112 Assignment 2 - server.sh

There is no client.sh file in my assignment. Clients use nc as in the spec, e.g.
    echo asssignment | nc 172.17.0.2 1234
    echo population | nc 172.17.0.2 1234 > population.png
    echo "FISHER LIBRARY SYDNEY UNIVERSITY" | nc 172.17.0.2 1234
The reply comes back on the same connection. If a client closes too early, keep it open with sleep (echo assignment; sleep 5) | nc localhost 1234

I have specified a POI request as a POI name or latitude,longitude, optionally with a distance
in metres (default 5000), e.g.  -33.8868,151.1897|500

Code for testcases have been written in server.sh, screenshots named client are from client terminal and server are from server terminal. 

Test case A (server not running): see screenshots - nc fails
(Connection refused) while ping shows the container is reachable.
In server.sh, cleanup() stops all nc listeners when the server is stopped,
so the port is really closed.

Test case B (second request from the same client while the first is still
running is rejected) as specified in run_job() and on_nc_message() in server.sh, Command TEST_DELAY=10 bash server.sh makes the busy window longer for testing. 

    
