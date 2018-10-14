for i in glances psutil bottle
do
  fpm -s python -t rpm $i
  fpm -s python -t deb $i
done
