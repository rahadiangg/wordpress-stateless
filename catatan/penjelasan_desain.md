# Penjelasan Desain

Saat ini aplikasi dapat diakses pada domain [https://wp.rahadian.dev](https://wp.rahadian.dev). Kemungkinan akses halaman ini diatas tanggal 3/4 Maret 2022 tidak dapat dilakukan.

![Desain Infra](Infra.jpg)

<br>

### Instance Template & Instance Group

*Instance template* digunakan untuk mendefinisikan VM yang nantinya akan dibuat. VM yang nanti dibuat akan menggunakan *container*, karena GCE sudah sejak lama support untuk menjalankan *container* secara langsung. Karena nanti ingin dilakukan *monitoring* dan *logging*, saya menambahkan *custom metadata* yang fungsinya untuk menghidupkan Stackdriver. Adapun custom metadatanya adalah:

```
google-logging-enabled = true
google-monitoring-enabled = true
```

Secara otomatis ketika VM di buat akan menjalankan 2 *container*. yaitu *container* aplikasi wordpress dan *container* stackdriver.

Setelah *instance template* terbentuk, selanjutnya membuat *manage instance group* yang berfungsi sebagai *collection* dari semua VM yang akan dibuat berdasarkan *instance template* tadi. Kita bisa pilih di zone mana saja VM akan dideploy, umumnya minimal 2 zone agar bisa terbetuk *high availability* dari aplikasi. Selain itu disini bisa didefinisikan *rule autoscaling* dari aplikasi. Contoh rule autoscaling yang saya terapkan adalah:

```
  autoscaling_policy {
    max_replicas    = 2 // maksimal vm
    min_replicas    = 1 // minimal vm
    cooldown_period = 60

    cpu_utilization {
      target = 0.7 // ketika sudah 70% akan scale up
    }
  }
```

### Container Registry

Untuk menampung file *image container* dari Docker, saya menggunakan *Container Registry* yang berlokasi di ASIA agar lebih cepat ketika *pull* dah *push image*. Contoh URI yang akan terbentuk  `asia.gcr.io/[project_id]/[image:tag]`

### Database

Database yang digunakan wordpress adalah MySQL. Disini saya menggukan layanan full manage untuk database yaitu CloudSQL dengan versi MySQL 8.0. Agar database juga *high availability* saya menghidupkan standby instance dan replica di berbeda zone dalam satu region. Untuk akses melalui IP Publik saya nonaktifkan karena pertimbangan keamanan.

### VPC Network Peering

Database yang sebelumnya dibuat akan menggunakan jaringan lokal untuk bisa di jangkau oleh aplikasi. Karena database full manage berada pada network VPC yang berbeda (Google), maka perlu dilakukan peering antar VPC.

### Static Assets with GCS

Karena aplikasi sudah didesain *high availability*, maka VM bisa di hancurkan dan dibuat kapan saja. Untuk menghidari kehilangan *assets* seperti gambar dan video, saya menggunakan Google Cloud Storage sebagai tempat menyimpan *assets* tersebut.

### Load Balancer

Aplikasi yang sebelumnya sudah didefinisikan pada Instance Group dapat deploy dizone mana saja secara random sesuai dengan algoritma dan ketersedia resource pada setiap zone. Agar traffic dapat didistribukan secara merata, disinilah peran Load Balancer. Load balancer yang didefiniskan disini sudah include dengan HTTPS agar akses aplikasi lebih aman. Selain Cloud CDN saya sertakan disini agar asset static bisa di load secara cepat oleh user.

### Monitoring & Logging

Untuk melakukan monitoring dari setiap event yang terjadi, Administrator dapat langsung melihat padaha menu Logs Explorer dan Monitoring. Kita bisa melihat detail dari setiap event karena sebelumnya sudah menghidupkan Stackdriver.

---
<br>
<br>
<br>

### Catatan Pribadi

Ini merupakan catatan pribadi yang saya temukan selama membuat infra ini

- Health check pada umumnya ke halaman root wordpress (/). Untuk diawal wordpress akan meredirect ke halaman setup, jadi harus segera di setup terlebih dahulu agar health check dapat bekerja dengan baik.
- Container error di instance group "Error: Cannot get auth token: Metadata server responded with status 404"
    - Buat service account khusus untuk mengtasi masalah ini dan terapkan block kode berikut
        ```
        service_account {
            scopes = [
                "userinfo-email",
                "cloud-platform"
            ]
        }
        ```
    - ref : https://cloud.google.com/sdk/gcloud/reference/alpha/compute/instances/set-scopes#--scopes