#!/bin/sh

echo "TEST 1: no set +e"
sh -c 'cp /no_such_file /tmp/out; echo "ECHO1: $? executed"'


echo ""
echo "TEST 2: set +e inside sh"
sh -c 'set +e; cp /no_such_file /tmp/out; echo "ECHO2: $? executed"'


echo ""
echo "TEST 3: set -e inside sh"
sh -c 'set -e; cp /no_such_file /tmp/out; echo "ECHO3: $? executed"'


echo ""
echo "TEST 4: set +e in outer shell, failing command in inner"
set +e
sh -c 'cp /no_such_file /tmp/out; echo "ECHO4: $? executed"'
