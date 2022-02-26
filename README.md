
# Wordpress Stateless

Ini merupakan project untuk menyelesaikan *challenge* membuat wordpress menjadi *stateless* agar bisa mengimplementasikan *High Availability*. Saat ini wordpress saya kemas menjadi sebuah *docker image* berserta *dependency* yang dibutuhkan. Saya juga menyediakan file `terraform` untuk keperluan *deployment* ke GCP
<br>
<br>
> Dokumentasi
> - [Penjelasan desain infra](/catatan/penjelasan_desain.md)

<br>
<br>

## Catatan

Dalam riset untuk membuat project ini saya menemukan banyak hal menarik. Pada dasarnya, wordpress merupakan aplikasi *statefull*. Untuk merubah menjadi *stateless* banyak sekali tantangan yang harus dihadapi, seperti:

- Bagaimana database bisa HA
    - Cukup menghidupkan HA tingkat region pada Cloud SQL (solved)
- Bagaimana static asset seperti gambar dan video tidak hilang saat instance melakukan scale down/up
    - Saya menggunakan plugin `WP Offload Media Lite` yang sudah saya masukan di *dependency* saat build image (solved)
- Bagaimana jika aplikasi sudah live dan administrator menambahkan plugin baru
    - Engineer perlu menambahkan plugin tersebut dan melakuakn rebuild image, kenapa seperti itu ? saya coba jelaskan dibawah ini

### Menyelesaikan masalah plugin

Untuk menyelesaikan masalah ini ada beberapa opsi yang **sebelumnya** menjadi pertimbangan, yaitu:

- Cloud Filestore sebagai NFS
    - biayanya perbulannya sangat mahal, paling murah ~$240
- Persistent Disk
    - ini cuman bisa 2 availability zone dalam satu region
    - hanya bisa maksimal 2 VM yang melakukan operasi read/write
    - ref:
        - https://cloud.google.com/compute/docs/disks/sharing-disks-between-vms
- Kubernetes dengan Persistent Disk
    - satu persistent disk gak bisa di attach lebih dari satu pod di mode read/write
    - terlalu berlebihan hanya untuk aplikasi monolith yang statefull seperti wordpress
    - jika pod di deploy beda node yang tidak ada persistent disk (sebelumnya), data tidak akan pindah.
    - ref: 
        - https://cloud.google.com/kubernetes-engine/docs/tutorials/persistent-disk
        - https://quantiphi.com/ways-to-deploy-a-scalable-wordpress-application-on-gcp/


> Dari latar belakang dan rumusan masalah diatas saya memutuskan untuk menggunakan container sebagai base dari aplikasi agar cool boot ketika di scale lebih cepat. Hal ini lebih baik ketimbangkan mendefinisikan `./startup-script.sh` karena goalsnya sama.