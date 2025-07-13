#!/bin/bash
cd /home/ec2-user/app
node index.js &   # or pm2 start index.js if you use PM2
